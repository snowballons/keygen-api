# frozen_string_literal: true

class User < ApplicationRecord
  MINIMUM_ADMIN_COUNT = 1

  include Keygen::PortableClass
  include PasswordResettable
  include Environmental
  include Accountable
  include Limitable
  include Orderable
  include Pageable
  include Roleable
  include Diffable

  belongs_to :group,
    optional: true
  has_many :second_factors, dependent: :destroy_async
  has_many :license_users, index_errors: true, dependent: :destroy_async
  has_many :owned_licenses, dependent: :destroy_async, class_name: License.name, foreign_key: :user_id, inverse_of: :owner
  has_many :user_licenses, index_errors: true, through: :license_users, source: :license
  has_many :licenses, union_of: %i[owned_licenses user_licenses], inverse_of: :users do
    def owned = where(owner: proxy_association.owner)
  end
  # FIXME(ezekg) Not sold on this naming but I can't think of anything better.
  #              Maybe collaborators or associated_users?
  has_many :teammates, -> user { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER).excluding(user) },
    through: :licenses,
    source: :users
  has_many :products, -> { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER) }, through: :licenses
  has_many :policies, -> { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER) }, through: :licenses
  has_many :license_entitlements, -> { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER) }, through: :licenses
  has_many :policy_entitlements, -> { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER) }, through: :licenses
  has_many :owned_machines, dependent: :destroy_async, class_name: Machine.name, foreign_key: :owner_id
  has_many :machines, -> { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER) }, through: :licenses do
    def owned = where(owner: proxy_association.owner)
  end
  has_many :components, through: :machines
  has_many :processes, through: :machines
  has_many :tokens, as: :bearer, dependent: :destroy_async
  has_many :sessions, as: :bearer, dependent: :destroy_async
  has_many :releases, -> { distinct.reorder("#{table_name}.created_at": DEFAULT_SORT_ORDER) },
    through: :products
  has_many :event_logs,
    as: :resource
  has_many :group_owners
  has_many :groups,
    through: :group_owners

  # NOTE(ezekg) This association is only used to preload a user's status, since
  #             the #status needs to check if a user has any active licenses.
  has_many :any_active_licenses, -> {
    where(<<~SQL.squish, start_date: 90.days.ago)
      licenses.created_at >= :start_date OR
        (licenses.last_validated_at IS NOT NULL AND licenses.last_validated_at >= :start_date) OR
        (licenses.last_check_out_at IS NOT NULL AND licenses.last_check_out_at >= :start_date) OR
        (licenses.last_check_in_at IS NOT NULL AND licenses.last_check_in_at >= :start_date)
    SQL
  },
    union_of: %i[owned_licenses user_licenses],
    class_name: License.name

  has_secure_password :password, validations: false
  has_environment
  has_account inverse_of: :users
  has_default_role :user
  has_permissions -> user {
      role = if user.present?
               user.role
             else
               nil
             end

      case role
      in Role(:admin | :developer | :support_agent | :sales_agent)
        Permission::ADMIN_PERMISSIONS
      in Role(:read_only)
        Permission::READ_ONLY_PERMISSIONS
      else
        Permission::USER_PERMISSIONS
      end
    },
    default: -> user {
      role = if user.present?
               user.role
             else
               nil
             end

      case role
      # FIXME(ezekg) Should these be separate permissions? All but admin are being
      #              deprecated, but still may be a good idea for correctness.
      #              When the admin is in an environment, we should also remove
      #              permissions such as account.billing.update, etc.
      in Role(:admin | :developer | :support_agent | :sales_agent)
        Permission::ADMIN_PERMISSIONS
      in Role(:read_only)
        Permission::READ_ONLY_PERMISSIONS
      else
        default_permissions = if user.present?
                                user.account.settings.default_user_permissions
                              else
                                nil
                              end

        default_permissions.presence || (
          # we're omitting some for backwards compatibility
          Permission::USER_PERMISSIONS - %w[
            account.read
            license.users.attach
            license.users.detach
            policy.read
            product.read
          ]
        )
      end
    }

  normalizes :email, with: -> email { email.downcase.strip }

  before_destroy :enforce_admin_minimums_on_account!
  before_update :enforce_admin_minimums_on_account!, if: -> { role.present? && role.changed? }

  # Tokens should be revoked when role is changed
  before_update -> { revoke_tokens!(except: Current.token) },
    if: -> { role&.name_changed? }

  validates :group,
    presence: { message: 'must exist' },
    scope: { by: :account_id },
    unless: -> {
      group_id_before_type_cast.nil?
    }

  validates :email, email: true, presence: true, length: { maximum: 255 }, uniqueness: { case_sensitive: false, scope: :account_id }
  validates :password, length: { minimum: 6, maximum: 72.bytes }, allow_nil: true
  validates :metadata, length: { maximum: 64, message: "too many keys (exceeded limit of 64 keys)" }

  validate on: :create, if: -> { id_before_type_cast.present? } do
    errors.add :id, :invalid, message: 'must be a valid UUID' if
      !UUID_RE.match?(id_before_type_cast)

    errors.add :id, :conflict, message: 'must not conflict with another user' if
      User.exists?(id)
  end

  validate on: %i[create update] do
    next unless
      group_id_changed?

    next unless
      group.present? && group.max_users.present?

    next unless
      group.users.count >= group.max_users

    errors.add :group, :user_limit_exceeded, message: "user count has exceeded maximum allowed by current group (#{group.max_users})"
  end

  scope :stdout_subscribers, -> (with_activity_from: 90.days.ago) {
    User.distinct_on(:email)
        .where(account: Account.active(with_activity_from:), stdout_unsubscribed_at: nil)
        .with_roles(:admin, :developer)
        .reorder(:email, :created_at)
  }

  scope :search_id, -> (term) {
    identifier = term.to_s
    return none if
      identifier.empty?

    return where(id: identifier) if
      UUID_RE.match?(identifier)

    where('users.id::text ILIKE ?', "%#{sanitize_sql_like(identifier)}%")
  }

  scope :search_email, -> (term) {
    return none if
      term.blank?

    where('users.email ILIKE ?', "%#{sanitize_sql_like(term)}%")
  }

  scope :search_first_name, -> (term) {
    return none if
      term.blank?

    where('users.first_name ILIKE ?', "%#{sanitize_sql_like(term)}%")
  }

  scope :search_last_name, -> (term) {
    return none if
      term.blank?

    where('users.last_name ILIKE ?', "%#{sanitize_sql_like(term)}%")
  }

  scope :search_full_name, -> (term) {
    first_name, last_name = term.to_s.split(' ', 2)

    search_first_name(first_name).search_last_name(last_name)
  }

  scope :search_name, -> (term) {
    search_full_name(term)
  }

  scope :search_metadata, -> (terms) {
    # FIXME(ezekg) Duplicated code for licenses, users, and machines.
    # FIXME(ezekg) Need to figure out a better way to do this. We need to be able
    #              to search for the original string values and type cast, since
    #              HTTP querystring parameters are strings.
    #
    #              Example we need to be able to search for:
    #
    #                { metadata: { external_id: "1624214616", internal_id: 1 } }
    #
    terms.reduce(self) do |scope, (key, value)|
      search_key       = key.to_s.underscore.parameterize(separator: '_')
      before_type_cast = { search_key => value }
      after_type_cast  =
        case value
        when 'true'
          { search_key => true }
        when 'false'
          { search_key => false }
        when 'null'
          { search_key => nil }
        when /^\d+$/
          { search_key => value.to_i }
        when /^\d+\.\d+$/
          { search_key => value.to_f }
        else
          { search_key => value }
        end

      scope.where('"users"."metadata" @> ?', before_type_cast.to_json)
        .or(
          scope.where('"users"."metadata" @> ?', after_type_cast.to_json)
        )
    end
  }

  scope :search_role, -> (term) {
    role_identifier = term.to_s
    return none if
      role_identifier.empty?

    return joins(:role).where(role: { id: role_identifier }) if
      UUID_RE.match?(role_identifier)

    scope = joins(:role).where('roles.name ILIKE ?', "%#{sanitize_sql_like(role_identifier)}%")
    return scope unless
      UUID_CHAR_RE.match?(role_identifier)

    scope.or(
      joins(:role).where(<<~SQL.squish, role_identifier.gsub(SANITIZE_TSV_RE, ' '))
        to_tsvector('simple', roles.id::text)
        @@
        to_tsquery(
          'simple',
          ''' ' ||
          ?     ||
          ' ''' ||
          ':*'
        )
      SQL
    )
  }

  scope :with_metadata, -> (meta) { search_metadata meta }
  scope :with_roles, -> (*roles) { joins(:role).where roles: { name: roles.flatten.map { |r| r.to_s.underscore } } }
  scope :with_role, -> (role) { joins(:role).where(roles: { name: role.to_s.underscore }) }
  scope :with_status, -> status {
    case status.to_s.upcase
    when 'BANNED'
      self.banned
    when 'INACTIVE'
      self.inactive
    when 'ACTIVE'
      self.active
    else
      self.none
    end
  }

  scope :accessible_by, -> accessor {
    case accessor
    in role: Role(:admin)
      all
    in role: Role(:product) # give products the ability to read all users
      with_role(:user)
    in role: Role(:environment)
      for_environment(accessor.id)
    in role: Role(:user)
      for_user(accessor.id)
    in role: Role(:license)
      for_license(accessor.id)
    else
      none
    end
  }

  scope :for_product, -> id {
    owned_licenses = License.select(1)
                            .where('licenses.user_id = users.id')
                            .where(product_id: id)
    user_licenses  = LicenseUser.select(1)
                                .joins(:license)
                                .where('license_users.user_id = users.id')
                                .where(license: { product_id: id })

    where(owned_licenses.arel.exists).or(
      where(user_licenses.arel.exists),
    )
  }
  scope :for_license, -> id {
    users = License.distinct
                   .reselect(arel_table[Arel.star])
                   .joins(:users)
                   .where(licenses: { id: })
                   .reorder(nil)

    from(users, table_name)
  }
  scope :for_group_owner, -> id { joins(group: :owners).where(group: { group_owners: { user_id: id } }).distinct }
  scope :for_user, -> user {
    for_license(License.for_user(user)) # users of any associated licenses
      .distinct
      .union(
        where(id: user), # itself
      )
      .reorder(
        "#{table_name}.created_at": DEFAULT_SORT_ORDER,
      )
  }
  scope :for_group, -> id { where(group: id) }
  scope :administrators, -> { with_roles(:admin, :developer, :read_only, :sales_agent, :support_agent) }
  scope :admins, -> { with_role(:admin) }
  scope :users, -> { with_role(:user) }
  scope :banned, -> { where.not(banned_at: nil) }
  scope :unbanned, -> { where(banned_at: nil) }
  scope :active, -> (t = 90.days.ago) {
    users = License.distinct
                   .reselect(arel_table[Arel.star])
                   .joins(:users)
                   .active
                   .reorder(nil)

    from(users, table_name)
      .unbanned
      .union(
        where('users.created_at >= ?', t).unbanned,
      )
      .reorder(
        "#{table_name}.created_at": DEFAULT_SORT_ORDER,
      )
  }
  scope :inactive, -> (t = 90.days.ago) {
    where('users.created_at < ?', t)
      .where.not(id: active)
      .unbanned
  }
  scope :assigned, -> (status = true) {
    sub_query = License.where('licenses.user_id = users.id').select(1).arel.exists

    if ActiveRecord::Type::Boolean.new.cast(status)
      where(sub_query)
    else
      where.not(sub_query)
    end
  }

  def self.emails = reorder(email: :asc).pluck(:email)

  # FIXME(ezekg) The :teammates association isn't the most efficient for large accounts,
  #              so we're going to use an optimized version of the ids reader.
  def teammate_ids
    self.class.for_license(License.for_user(self))
              .excluding(self)
              .reorder(nil)
              .ids
  end

  # FIXME(ezekg) Selecting on ID isn't supported by our association scopes because
  #              we're using DISTINCT and reordering on created_at.
  def machine_ids  = machines.reorder(nil).ids
  def product_ids  = products.reorder(nil).ids
  def policy_ids   = policies.reorder(nil).ids

  def entitlement_codes = entitlements.reorder(nil).codes
  def entitlement_ids   = entitlements.reorder(nil).ids
  def entitlements
    entl = Entitlement.where(account_id: account_id).distinct

    entl.left_outer_joins(:policy_entitlements, :license_entitlements)
        .where(policy_entitlements: { policy_id: policy_ids })
        .or(
          entl.where(license_entitlements: { license_id: license_ids })
        )
  end

  def entitled?(*identifiers)
    entls = entls.flatten.compact
    return true if
      entls.empty?

    unless entls.all?(Entitlement)
      entls = Entitlement.where(id: entls)
                         .or(
                           Entitlement.where(code: entls),
                         )
    end

    (entls & entitlements).size == entls.size
  end
  alias_method :entitlements?, :entitled?

  def unentitled?(...) = !entitled?(...)

  def group_ids? = group_ids.any?

  def group!
    raise Keygen::Error::NotFoundError.new(model: Group.name) unless
      group.present?

    group
  end

  def full_name
    return nil if first_name.nil? || last_name.nil?

    [first_name, last_name].join " "
  end

  def email_parts = email.match(EMAIL_PARTS_RE)&.named_captures&.with_indifferent_access
  def email_user  = email_parts[:user]
  def email_host  = email_parts[:host]

  def email_checker        = @email_checker ||= EmailCheck::EmailAddress.new(email)
  def email_domain_has_mx? = @email_mx      ||= email_checker.domain_has_mx?

  def free_or_disposable_email?
    email_checker.free_email_provider? || email_checker.disposable? || email_checker.educational?
  end

  def single_sign_on_enabled? = !role.user? && account.sso?
  alias :sso_enabled? :single_sign_on_enabled?

  def password?
    password_digest?
  end

  def active?(t = 90.days.ago)
    created_at >= t || any_active_licenses.any?
  end

  def inactive?(t = 90.days.ago)
    created_at < t && any_active_licenses.empty?
  end

  def banned?
    banned_at?
  end

  def ban!
    update!(banned_at: Time.current)
  end

  def unban!
    update!(banned_at: nil)
  end

  def status
    case
    when banned?
      :BANNED
    when active?
      :ACTIVE
    else
      :INACTIVE
    end
  end

  def second_factor_enabled?
    second_factors.enabled.exists?
  end

  def verify_second_factor(otp)
    return false unless second_factor_enabled?

    second_factor = second_factors.enabled.last

    second_factor.verify(otp)
  end

  def revoke_tokens!(except: nil)
    s = if except.present?
          tokens.where.not(id: except)
        else
          tokens
        end

    s.destroy_all
  end

  def revoke_tokens(...)
    revoke_tokens!(...)
  rescue ActiveRecord::RecordInvalid
    nil
  end

  def enforce_admin_minimums_on_account! = enforce_admin_minimums_for(:account, abort_on_error: true)
  def enforce_admin_minimums_for(association_name, abort_on_error: false)
    association = public_send(association_name)
    return if
      association.nil?

    return if
      association.marked_for_destruction? ||
      association.destroyed?

    return if
      !has_role?(:admin) && !was_role?(:admin)

    other_admins = association.admins.preload(role: %i[role_permissions]).where.not(id:)
    admin_count  = other_admins.size
    unless marked_for_destruction?
      admin_count += 1 # current admin
    end

    # Real count is not including any of the current role changes,
    # so we'll adjust the number based on the current change.
    case
    when !has_role?(:admin) && was_role?(:admin)
      admin_count -= 1
    when has_role?(:admin) && !was_role?(:admin)
      admin_count += 1
    end

    case
    # When other admins: do not allow their permissions to be changed if no other admin has a full permission set.
    # When sole admin: do not allow their permissions to be changed.
    when admin_count  > MINIMUM_ADMIN_COUNT && !all_permissions? && !role_changed? && other_admins.none?(&:all_permissions?),
         admin_count == MINIMUM_ADMIN_COUNT && !all_permissions? && !role_changed?
      errors.add association_name, :admins_required, message: "#{association_name} must have at least #{MINIMUM_ADMIN_COUNT} admin user with a full permission set"

      throw :abort if abort_on_error
    # When no admins, do not allow the last admin to be destroyed or their role to be changed.
    when admin_count < MINIMUM_ADMIN_COUNT && marked_for_destruction?,
         admin_count < MINIMUM_ADMIN_COUNT && role_changed?
      errors.add association_name, :admins_required, message: "#{association_name} must have at least #{MINIMUM_ADMIN_COUNT} admin user"

      throw :abort if abort_on_error
    end
  end
end
