# frozen_string_literal: true

class License < ApplicationRecord
  include Envented::Callbacks
  include Keygen::PortableClass
  include Denormalizable
  include Environmental
  include Accountable
  include Limitable
  include Orderable
  include Tokenable
  include Pageable
  include Roleable
  include Diffable

  belongs_to :policy
  # NOTE(ezekg) This is a denormalized association and is automatically
  #             pulled in from the policy. Purposefully defined after
  #             the policy association for order of validation.
  belongs_to :product
  belongs_to :group,
    optional: true
  belongs_to :owner,
    foreign_key: :user_id,
    class_name: User.name,
    optional: true
  has_many :license_users, dependent: :destroy_async
  has_many :licensees, through: :license_users, source: :user
  has_many :users, union_of: %i[licensees owner], inverse_of: :licenses
  has_many :license_entitlements, dependent: :delete_all
  has_many :policy_entitlements, through: :policy
  has_many :tokens, as: :bearer, dependent: :destroy_async
  has_many :sessions, as: :bearer, dependent: :destroy_async
  has_many :machines, dependent: :destroy_async
  has_many :components, through: :machines
  has_many :processes, through: :machines
  has_many :releases, through: :product
  has_many :event_logs,
    as: :resource

  has_environment default: -> { policy&.environment_id }
  has_account default: -> { policy&.account_id }, inverse_of: :licenses
  has_role :license
  has_permissions Permission::LICENSE_PERMISSIONS,
    default: -> license {
      default_permissions = if license.present?
                              license.account.settings.default_license_permissions
                            else
                              nil
                            end

      default_permissions.presence || (
        # we're omitting some for backwards compatibility
        Permission::LICENSE_PERMISSIONS - %w[
          account.read
          product.read
          policy.read
          user.read
        ]
      )
  }

  denormalizes :product_id, from: :policy
  denormalizes :policy_id, to: :machines

  encrypts :key,
    deterministic: true

  # Used for legacy encrypted licenses
  attr_reader :raw

  before_create :enforce_active_licensed_user_limit_on_account!
  before_create -> { self.protected = policy.protected? }, if: -> { policy.present? && protected.nil? }
  before_create :set_first_check_in, if: -> { policy.present? && requires_check_in? }
  before_create :set_expiry_on_creation, if: -> { expiry.nil? && policy.present? }
  before_create :autogenerate_key, if: -> { key.nil? && policy.present? }
  before_create :crypt_key, if: -> { scheme? && !legacy_encrypted? }

  # Licenses automatically inherit their owner's group ID. We're using before_validation
  # instead of before_create so that this can be run when the owner is changed as well,
  # and so that we can keep our group limit validations in play.
  before_validation -> { self.group_id = owner.group_id },
    if: -> { owner_id_changed? && owner.present? && group_id.nil? },
    on: %i[create update]

  on_exclusive_event 'license.validation.*', :set_expiry_on_first_validation!,
    # NOTE(ezekg) No auto-release for high volume events to rate limit
    auto_release_lock: false,
    unless: :expiry?

  on_exclusive_event 'machine.created', :set_expiry_on_first_activation!,
    auto_release_lock: true,
    unless: :expiry?

  on_exclusive_event 'license.usage.incremented', :set_expiry_on_first_use!,
    auto_release_lock: false,
    unless: :expiry?

  on_exclusive_event 'artifact.downloaded', :set_expiry_on_first_download!,
    auto_release_lock: true,
    unless: :expiry?

  on_exclusive_event 'release.downloaded', :set_expiry_on_first_download!,
    auto_release_lock: true,
    unless: :expiry?

  on_exclusive_event 'release.upgraded', :set_expiry_on_first_download!,
    auto_release_lock: true,
    unless: :expiry?

  validates :policy,
    scope: { by: :account_id }

  # Validate this association only if we've been given an owner (because it's optional)
  validates :owner,
    presence: { message: 'must exist' },
    scope: { by: :account_id },
    unless: -> {
      # Using before type cast because non-UUIDs are silently ignored and we
      # want to raise an error in that case
      owner_id_before_type_cast.nil?
    }

  # Same for the group association
  validates :group,
    presence: { message: 'must exist' },
    scope: { by: :account_id },
    unless: -> {
      group_id_before_type_cast.nil?
    }

  validate on: :create, if: -> { id_before_type_cast.present? } do
    errors.add :id, :invalid, message: 'must be a valid UUID' if
      !UUID_RE.match?(id_before_type_cast)

    errors.add :id, :conflict, message: 'must not conflict with another license' if
      License.exists?(id)
  end

  validate on: :create, unless: -> { policy.nil? } do
    errors.add :key, :conflict, message: "must not conflict with another license's identifier (UUID)" if key.present? && key =~ UUID_RE && account.licenses.exists?(key)

    # This is for our original "encrypted" keys only (legacy scheme)
    errors.add :key, :not_supported, message: "cannot be specified for a legacy encrypted license" if key.present? && legacy_encrypted?
  end

  # Disallow user overages according to policy overage strategy
  validate on: :update do
    next unless
      owner_id? && owner_id_changed? # only run when owner is attached

    next unless
      max_users?

    next if
      always_allow_overage?

    next unless
      users_count > max_users

    next if
      allow_1_25x_overage? && users_count <= max_users * 1.25

    next if
      allow_1_5x_overage? && users_count <= max_users * 1.5

    next if
      allow_2x_overage? && users_count <= max_users * 2

    errors.add :users, :limit_exceeded, message: "user count has exceeded maximum allowed for license (#{max_users})"
  end

  validate on: :update do |license|
    next unless license.uses_changed?
    next if license.uses.nil? || license.max_uses.nil?
    next if license.uses <= license.max_uses

    license.errors.add :uses, :limit_exceeded, message: "usage exceeds maximum allowed for license (#{license.max_uses})"
  end

  validate on: :update do |license|
    next unless
      license.policy_id_changed? &&
      license.policy_id_was.present? &&
      license.policy_id.present?

    prev_policy = account.policies.find_by(id: policy_id_was)
    next_policy = license.policy

    next if
      prev_policy.nil?

    case
    when next_policy.encrypted? != prev_policy.encrypted?
      license.errors.add :policy, :not_compatible, message: "cannot change from an encrypted policy to an unencrypted policy (or vice-versa)"
    when next_policy.pool? != prev_policy.pool?
      license.errors.add :policy, :not_compatible, message: "cannot change from a pooled policy to an unpooled policy (or vice-versa)"
    when next_policy.scheme != prev_policy.scheme
      license.errors.add :policy, :not_compatible, message: "cannot change to a policy with a different scheme"
    when next_policy.machine_uniqueness_strategy != prev_policy.machine_uniqueness_strategy
      license.errors.add :policy, :not_compatible, message: "cannot change to a policy with a more strict machine uniqueness strategy" if
        next_policy.machine_uniqueness_strategy_rank > prev_policy.machine_uniqueness_strategy_rank
    when next_policy.component_uniqueness_strategy != prev_policy.component_uniqueness_strategy
      license.errors.add :policy, :not_compatible, message: "cannot change to a policy with a more strict component uniqueness strategy" if
        next_policy.component_uniqueness_strategy_rank > prev_policy.component_uniqueness_strategy_rank
    end
  end

  validate on: %i[create update] do
    next unless
      group_id_changed?

    next unless
      group.present? && group.max_licenses.present?

    next unless
      group.licenses.count >= group.max_licenses

    errors.add :group, :license_limit_exceeded, message: "license count has exceeded maximum allowed by current group (#{group.max_licenses})"
  end

  # Assert owner is not a license user (i.e. licensee)
  validate on: %i[create update] do
    next unless
      owner_id_changed?

    next unless
      owner.present?

    if licensees.exists?(owner.id)
      errors.add :owner, :invalid, message: 'already exists (user is attached through users)'
    end
  end

  validates :metadata, length: { maximum: 64, message: "too many keys (exceeded limit of 64 keys)" }
  validates :uses, numericality: { greater_than_or_equal_to: 0 }

  # Key is immutable so we only need to assert on create
  validates :key,
    exclusion: { in: EXCLUDED_ALIASES, message: "is reserved" },
    uniqueness: { case_sensitive: true, scope: :account_id },
    length: { minimum: 1, maximum: 100.kilobytes },
    unless: -> { key.nil? },
    on: :create

  # Non-crypted keys should be 6 character minimum
  validates :key,
    length: { minimum: 6, maximum: 100.kilobytes },
    if: -> { key.present? && !scheme? },
    on: :create

  validates :max_machines,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true,
    if: -> { max_machines_override? }

  validates :max_machines,
    numericality: { greater_than_or_equal_to: 1, message: 'must be greater than or equal to 1 for floating policy' },
    allow_nil: true,
    if: -> { max_machines_override? && floating? }

  validates :max_machines,
    numericality: { equal_to: 1, message: 'must be equal to 1 for non-floating policy' },
    allow_nil: true,
    if: -> { max_machines_override? && node_locked? }

  validates :max_cores,
    numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true,
    if: -> { max_cores_override? }

  validates :max_uses,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true,
    if: -> { max_uses_override? }

  validates :max_processes,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true,
    if: -> { max_processes_override? }

  validates :max_users,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true,
    if: -> { max_users_override? }

  scope :search_id, -> (term) {
    identifier = term.to_s
    return none if
      identifier.empty?

    return where(id: identifier) if
      UUID_RE.match?(identifier)

    where('licenses.id::text ILIKE ?', "%#{sanitize_sql_like(identifier)}%")
  }

  scope :search_key,  -> key  { where(key:) }
  scope :search_name, -> term {
    return none if
      term.blank?

    where('licenses.name ILIKE ?', "%#{sanitize_sql_like(term)}%")
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

      scope.where('licenses.metadata @> ?', before_type_cast.to_json)
        .or(
          scope.where('licenses.metadata @> ?', after_type_cast.to_json)
        )
    end
  }

  scope :search_owner, -> (term) {
    owner_identifier = term.to_s
    return none if
      owner_identifier.empty?

    return where(user_id: owner_identifier) if
      UUID_RE.match?(owner_identifier)

    scope = joins(:owner).where(owner: { email: owner_identifier })
                         .or(
                           joins(:owner).where('owner.email ILIKE ?', "%#{sanitize_sql_like(owner_identifier)}%"),
                         )
    return scope unless
      UUID_CHAR_RE.match?(owner_identifier)

    scope.or(
      joins(:owner).where(<<~SQL.squish, owner_identifier.gsub(SANITIZE_TSV_RE, ' '))
        to_tsvector('simple', owner.id::text)
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

  scope :search_user, -> (term) {
    user_identifier = term.to_s
    return none if
      user_identifier.empty?

    return joins(:users).where(users: { id: user_identifier }) if
      UUID_RE.match?(user_identifier)

    scope = joins(:users).where(users: { email: user_identifier })
                         .or(
                           joins(:users).where('users.email ILIKE ?', "%#{sanitize_sql_like(user_identifier)}%"),
                         )
    return scope unless
      UUID_CHAR_RE.match?(user_identifier)

    scope.or(
      joins(:users).where(<<~SQL.squish, user_identifier.gsub(SANITIZE_TSV_RE, ' '))
        to_tsvector('simple', users.id::text)
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

  scope :search_product, -> (term) {
    product_identifier = term.to_s
    return none if
      product_identifier.empty?

    return joins(:policy).where(policy: { product_id: product_identifier }) if
      UUID_RE.match?(product_identifier)

    scope = joins(policy: :product).where('products.name ILIKE ?', "%#{sanitize_sql_like(product_identifier)}%")
    return scope unless
      UUID_CHAR_RE.match?(product_identifier)

    scope.or(
      joins(policy: :product).where(<<~SQL.squish, product_identifier.gsub(SANITIZE_TSV_RE, ' '))
        to_tsvector('simple', products.id::text)
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

  scope :search_policy, -> (term) {
    policy_identifier = term.to_s
    return none if
      policy_identifier.empty?

    return where(policy_id: policy_identifier) if
      UUID_RE.match?(policy_identifier)

    scope = joins(:policy).where('policies.name ILIKE ?', "%#{sanitize_sql_like(policy_identifier)}%")
    return scope unless
      UUID_CHAR_RE.match?(policy_identifier)

    scope.or(
      joins(:policy).where(<<~SQL.squish, policy_identifier.gsub(SANITIZE_TSV_RE, ' '))
        to_tsvector('simple', policy_id::text)
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

  scope :active, -> (start_date = 90.days.ago) {
    # exclude licenses owned by banned users (if any)
    left_outer_joins(:owner)
      .where(owner: { banned_at: nil })
      # include any licenses newer than :t or with any activity
      .where(<<~SQL.squish, start_date:)
        licenses.created_at >= :start_date OR
          (licenses.last_validated_at IS NOT NULL AND licenses.last_validated_at >= :start_date) OR
          (licenses.last_check_out_at IS NOT NULL AND licenses.last_check_out_at >= :start_date) OR
          (licenses.last_check_in_at IS NOT NULL AND licenses.last_check_in_at >= :start_date)
      SQL
  }

  scope :inactive, -> (start_date = 90.days.ago) {
    # exclude licenses owned by banned users (if any)
    left_outer_joins(:owner)
      .where(owner: { banned_at: nil })
      # include licenses older than :t without any activity
      .where(<<~SQL.squish, start_date:)
        licenses.created_at < :start_date AND
          (licenses.last_validated_at IS NULL OR licenses.last_validated_at < :start_date) AND
          (licenses.last_check_out_at IS NULL OR licenses.last_check_out_at < :start_date) AND
          (licenses.last_check_in_at IS NULL OR licenses.last_check_in_at < :start_date)
      SQL
  }

  scope :activity, -> (inside: nil, outside: nil, before: nil, after: nil) {
    begin
      case
      when inside.present?
        s = inside.to_s.match?(/\A\d+\z/) ? "PT#{inside.to_s}S".upcase : "P#{inside.to_s.delete_prefix('P').upcase}"
        d = ActiveSupport::Duration.parse(s)

        active(d.ago)
      when outside.present?
        s = outside.to_s.match?(/\A\d+\z/) ? "PT#{outside.to_s}S".upcase : "P#{outside.to_s.delete_prefix('P').upcase}"
        d = ActiveSupport::Duration.parse(s)

        inactive(d.ago)
      when before.present?
        t = before.to_s.match?(/\A\d+\z/) ? Time.at(before.to_i) : before.to_time

        inactive(t)
      when after.present?
        t = after.to_s.match?(/\A\d+\z/) ? Time.at(after.to_i) : after.to_time

        active(t)
      else
        none
      end
    rescue ActiveSupport::Duration::ISO8601Parser::ParsingError,
           ArgumentError # to_time raises for invalid input
      none
    end
  }

  scope :suspended, -> (status = true) { where suspended: ActiveRecord::Type::Boolean.new.cast(status) }
  scope :assigned, -> (status = true) {
    if ActiveRecord::Type::Boolean.new.cast(status)
      where_assoc_exists(:owner).or(
        where_assoc_exists(:licensees),
      )
    else
      where_assoc_not_exists(:owner)
        .where_assoc_not_exists(:licensees)
    end
  }
  scope :unassigned, -> (status = true) {
    assigned(!ActiveRecord::Type::Boolean.new.cast(status))
  }
  scope :activated, -> (status = true) {
    if ActiveRecord::Type::Boolean.new.cast(status)
      where('machines_count >= 1')
    else
      where('machines_count <= 0')
    end
  }
  scope :activations, -> (eq: nil, gt: nil, gte: nil, lt: nil, lte: nil) {
    case
    when eq.present?
      where('machines_count = ?', eq.to_i)
    when gt.present?
      where('machines_count > ?', gt.to_i)
    when gte.present?
      where('machines_count >= ?', gte.to_i)
    when lt.present?
      where('machines_count < ?', lt.to_i)
    when lte.present?
      where('machines_count <= ?', lte.to_i)
    else
      none
    end
  }
  scope :expiring, -> (status = true) {
    if ActiveRecord::Type::Boolean.new.cast(status)
      where 'expiry IS NOT NULL AND expiry > ? AND expiry < ?', Time.current, 3.days.from_now
    else
      where 'expiry IS NULL OR expiry < ? OR expiry > ?', Time.current, 3.days.from_now
    end
  }
  scope :expired, -> (status = true) {
    if ActiveRecord::Type::Boolean.new.cast(status)
      where 'expiry IS NOT NULL AND expiry < ?', Time.current
    else
      where 'expiry IS NULL OR expiry >= ?', Time.current
    end
  }
  scope :expires, -> (within: nil, in: nil, before: nil, after: nil) {
    within ||= binding.local_variable_get(:in)

    begin
      case
      when within.present?
        s = within.to_s.match?(/\A\d+\z/) ? "PT#{within.to_s}S".upcase : "P#{within.to_s.delete_prefix('P').upcase}"
        d = ActiveSupport::Duration.parse(s)

        where 'expiry IS NOT NULL AND expiry >= ? AND expiry <= ?', Time.current, d.from_now
      when before.present?
        t = before.to_s.match?(/\A\d+\z/) ? Time.at(before.to_i) : before.to_time

        where 'expiry IS NOT NULL AND expiry >= ? AND expiry <= ?', Time.current, t
      when after.present?
        t = after.to_s.match?(/\A\d+\z/) ? Time.at(after.to_i) : after.to_time

        where 'expiry IS NOT NULL AND expiry >= ? AND expiry >= ?', Time.current, t
      else
        none
      end
    rescue ActiveSupport::Duration::ISO8601Parser::ParsingError,
           ArgumentError # to_time raises for invalid input
      none
    end
  }
  scope :banned, -> {
    joins(:owner).where.not(owner: { banned_at: nil })
  }
  scope :with_metadata, -> (meta) { search_metadata meta }
  scope :with_status, -> status {
    case status.to_s.upcase
    when 'BANNED'
      self.banned
    when 'SUSPENDED'
      self.suspended
    when 'EXPIRED'
      self.expired
    when 'EXPIRING'
      self.expiring
    when 'INACTIVE'
      self.inactive
    when 'ACTIVE'
      self.active
    else
      self.none
    end
  }
  scope :for_policy, -> policy { where(policy:) }
  scope :for_user, -> user {
    licenses = User.distinct
                   .reselect(arel_table[Arel.star])
                   .joins(:licenses)
                   .reorder(nil)

    case user
    when User, UUID_RE
      from(licenses.where(users: { id: user }), table_name)
    else
      from(
        licenses.where(users: { id: user })
                .or(
                  licenses.where(users: { email: user }),
                ),
        table_name,
      )
    end
  }
  scope :for_owner, -> owner {
    case owner
    when User, UUID_RE, nil
      where(owner:)
    else
      joins(:owner).where(owner: { id: owner })
                   .or(
                     joins(:owner).where(owner: { email: owner }),
                   )
    end
  }
  scope :for_product, -> id { where(product_id: id) }
  scope :for_machine, -> (id) { joins(:machines).where machines: { id: id } }
  scope :for_fingerprint, -> (fp) { joins(:machines).where machines: { fingerprint: fp } }
  scope :for_group, -> id { where(group: id) }
  scope :for_group_owner, -> id { joins(group: :owners).where(group: { group_owners: { user_id: id } }) }
  scope :for_license, -> id { where(id: id) }

  delegate :requires_check_in?, :check_in_interval, :check_in_interval_count,
    :check_in_interval_count?, :check_in_interval?,
    :duration, :encrypted?, :legacy_encrypted?, :scheme?, :scheme,
    :strict?, :pool?, :node_locked?, :floating?,
    :always_allow_overage?, :allow_overage?, :allow_1_25x_overage?, :allow_1_5x_overage?, :allow_2x_overage?, :no_overage?,
    :revoke_access?, :restrict_access?, :maintain_access?, :allow_access?,
    :process_lease_per_machine?, :process_lease_per_license?, :process_lease_per_user?,
    :machine_lease_per_license?, :machine_lease_per_user?,
    :expire_from_creation?,
    :expire_from_first_validation?,
    :expire_from_first_activation?,
    :expire_from_first_use?,
    :expire_from_first_download?,
    :renew_from_expiry?, :renew_from_now?, :renew_from_now_if_expired?,
    :supports_token_auth?,
    :supports_license_auth?,
    :supports_session_auth?,
    :supports_mixed_auth?,
    :supports_auth?,
    :require_heartbeat?,
    to: :policy,
    allow_nil: true

  # override permissions reader to intersect with owner's permissions
  def permissions
    return Permission.none unless
      role.present?

    return role.permissions unless
      owner.present?

    # When license has wildcard permissions, defer to owner.
    return owner.permissions if
      role.permissions.include?(Permission.wildcard)

    # When owner has wildcard permissions, defer to license.
    return role.permissions if
      owner.permissions.include?(Permission.wildcard)

    # A license's permission set is the intersection of its owner's
    # permissions and its own permissions.
    Permission.wrap(owner.permissions & role.permissions)
  end

  # FIXME(ezekg) Should we eventually rename the user_id column?
  def owner_id_before_type_cast = user_id_before_type_cast
  def owner_id_changed?         = user_id_changed?
  def owner_id? = user_id?
  def owner_id  = user_id
  def owner_id=(id)
    self.user_id = id
  end

  def entitlement_codes = entitlements.reorder(nil).codes
  def entitlement_ids   = entitlements.reorder(nil).ids
  def entitlements
    entl = Entitlement.where(account_id: account_id).distinct

    entl.left_outer_joins(:policy_entitlements, :license_entitlements)
        .where(policy_entitlements: { policy_id: policy_id })
        .or(
          entl.where(license_entitlements: { license_id: id })
        )
  end

  def entitled?(*entls)
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

  def group!
    raise Keygen::Error::NotFoundError.new(model: Group.name) unless
      group.present?

    group
  end

  def expires? = expiry?

  def status
    case
    when banned?
      :BANNED
    when suspended?
      :SUSPENDED
    when expired?
      :EXPIRED
    when expiring?
      :EXPIRING
    when inactive?
      :INACTIVE
    else
      :ACTIVE
    end
  end


  def max_machines  = max_machines_override? ? max_machines_override : policy&.max_machines
  def max_machines? = max_machines.present?
  def max_machines=(value)
    self.max_machines_override = value
  end

  def max_cores  = max_cores_override? ? max_cores_override : policy&.max_cores
  def max_cores? = max_cores.present?
  def max_cores=(value)
    self.max_cores_override = value
  end

  def max_uses  = max_uses_override? ? max_uses_override : policy&.max_uses
  def max_uses? = max_uses.present?
  def max_uses=(value)
    self.max_uses_override = value
  end

  def max_processes  = max_processes_override? ? max_processes_override : policy&.max_processes
  def max_processes? = max_processes.present?
  def max_processes=(value)
    self.max_processes_override = value
  end

  def max_users  = max_users_override? ? max_users_override : policy&.max_users
  def max_users? = max_users.present?
  def max_users=(value)
    self.max_users_override = value
  end

  def users_count = license_users_count + (owner_id? ? 1 : 0)

  def protected?
    return policy.protected? if protected.nil?

    protected
  end

  def banned?
    return false if user_id.nil? || owner.nil?

    owner.banned?
  end

  def suspended?
    suspended
  end

  def expired?
    return false if expiry.nil?

    expiry < Time.current
  end

  def expiring?
    return false if
      expiry.nil?

    expiry > Time.current && expiry < 3.days.from_now
  end

  def active?(t = 90.days.ago)
    created_at >= t ||
      (last_validated_at? && last_validated_at >= t) ||
      (last_check_out_at? && last_check_out_at >= t) ||
      (last_check_in_at?  && last_check_in_at  >= t)
  end

  def inactive?
    !active?
  end

  def check_in_overdue?
    return false unless
      check_in_interval_count? && check_in_interval? &&
      last_check_in_at? && requires_check_in?

    last_check_in_at < check_in_interval_count.send(check_in_interval).ago
  end

  def next_check_in_at
    return nil unless
      check_in_interval_count? && check_in_interval? &&
      last_check_in_at? && requires_check_in?

    last_check_in_at + check_in_interval_count.send(check_in_interval)
  end

  def check_in!
    return false unless requires_check_in?

    update!(last_check_in_at: Time.current)
  end

  def renew!
    return false if
      expiry.nil? || policy.duration.nil?

    duration = ActiveSupport::Duration.build(policy.duration)
    now      = Time.current

    case
    when renew_from_expiry?
      self.expiry = expiry + duration
    when renew_from_now?
      self.expiry = now + duration
    when renew_from_now_if_expired?
      self.expiry = (expired? ? now : expiry) + duration
    end

    save!
  end

  def suspend!   = update!(suspended: true)
  def reinstate! = update!(suspended: false)

  def transfer!(new_policy)
    self.policy = new_policy

    if new_policy.present? && new_policy.reset_expiry_on_transfer?
      if new_policy.duration?
        self.expiry = Time.current + ActiveSupport::Duration.build(new_policy.duration)
      else
        self.expiry = nil
      end
    end

    save!
  end

  private

  attr_accessor :seed_key

  def default_seed_key
    case scheme
    when "RSA_2048_PKCS1_ENCRYPT"
      JSON.generate(id: id, created: created_at.iso8601(3), duration: duration, expiry: expiry&.iso8601(3))
    when "RSA_2048_JWT_RS256"
      claims = { jti: SecureRandom.uuid, iss: 'https://keygen.sh', aud: account.id, sub: id, iat: created_at.to_i, nbf: created_at.to_i }
      claims[:exp] = expiry.to_i if expiry.present?

      JSON.generate(claims)
    else
      JSON.generate(
        account: { id: account.id },
        product: { id: product.id },
        policy: { id: policy.id, duration: policy.duration },
        user: if owner.present?
                { id: owner.id, email: owner.email }
              else
                nil
              end,
        license: {
          id: id,
          created: created_at.iso8601(3),
          expiry: expiry&.iso8601(3),
        }
      )
    end
  end

  def set_first_check_in
    return if last_check_in_at.present?

    self.last_check_in_at = Time.current
  end

  def set_expiry_on_creation
    return unless
      expire_from_creation? &&
      duration.present? &&
      expiry.nil?

    self.expiry = Time.current + ActiveSupport::Duration.build(duration)
  end

  def set_expiry_on_first_validation!
    return unless
      expire_from_first_validation? &&
      duration.present? &&
      expiry.nil?

    update!(expiry: Time.current + ActiveSupport::Duration.build(duration))
  end

  def set_expiry_on_first_activation!
    return unless
      expire_from_first_activation? &&
      duration.present? &&
      expiry.nil?

    update!(expiry: Time.current + ActiveSupport::Duration.build(duration))
  end

  def set_expiry_on_first_use!
    return unless
      expire_from_first_use? &&
      duration.present? &&
      expiry.nil?

    update!(expiry: Time.current + ActiveSupport::Duration.build(duration))
  end

  def set_expiry_on_first_download!
    return unless
      expire_from_first_download? &&
      duration.present? &&
      expiry.nil?

    update!(expiry: Time.current + ActiveSupport::Duration.build(duration))
  end

  def autogenerate_key
    return if
      key.present?

    # We need to define an ID and timestamps beforehand since they may
    # be used in an auto-generated key
    self.id         ||= SecureRandom.uuid if scheme?
    self.created_at ||= Time.current
    self.updated_at ||= created_at

    case
    when legacy_encrypted?
      generate_legacy_encrypted_key!
    when scheme?
      generate_seed_key!
    when pool?
      generate_pooled_key!
    else
      generate_unencrypted_key!
    end

    # We're raising a RecordInvalid exception so that the transaction will be
    # halted and rolled back (since our record is invalid without a key)
    raise ActiveRecord::RecordInvalid if key.nil?
  end

  # FIXME(ezekg) All of these callbacks need to be moved into a license key
  #              encryption/signing service
  def crypt_key
    return unless
      key.present?

    self.id         ||= SecureRandom.uuid
    self.created_at ||= Time.current
    self.updated_at ||= created_at

    # Apply template variables e.g. {{expiry}} and {{id}}
    formatted_key = TemplateFormatService.call(
      template: key,
      account: account&.id,
      product: product&.id,
      policy: policy&.id,
      user: owner&.id,
      email: owner&.email,
      created: created_at&.iso8601(3),
      expiry: expiry&.iso8601(3),
      duration: duration,
      id: id,
    )

    self.seed_key = formatted_key
    self.key      = nil

    case scheme
    when "RSA_2048_PKCS1_ENCRYPT"
      generate_pkcs1_encrypted_key!
    when "RSA_2048_PKCS1_SIGN"
      generate_pkcs1_signed_key! version: 1
    when "RSA_2048_PKCS1_PSS_SIGN"
      generate_pkcs1_pss_signed_key! version: 1
    when "RSA_2048_JWT_RS256"
      generate_jwt_rs256_key!
    when "RSA_2048_PKCS1_SIGN_V2"
      generate_pkcs1_signed_key! version: 2
    when "RSA_2048_PKCS1_PSS_SIGN_V2"
      generate_pkcs1_pss_signed_key! version: 2
    when "ED25519_SIGN"
      generate_ed25519_signed_key!
    end

    raise ActiveRecord::RecordInvalid if key.nil?
  end

  def generate_seed_key!
    self.key = default_seed_key
  end

  def generate_pooled_key!
    pooled_key = policy.pop!

    self.key = pooled_key.key
  rescue Policy::EmptyPoolError
    errors.add :policy, :pool_empty, message: "pool is empty"
  end

  def generate_legacy_encrypted_key!
    @raw, enc = generate_hashed_token :key, version: "v1" do |token|
      # Replace first n characters with our id so that we can do a lookup
      # on the encrypted key
      token.gsub(/\A.{#{UUID_LENGTH}}/, id.delete("-"))
           .scan(/.{#{UUID_LENGTH}}/).join("-")
    end

    self.key = enc
  end

  def generate_unencrypted_key!
    self.key = generate_token :key, length: 16 do |token|
      # Split every n characters, e.g. XXXX-XXXX-XXXX
      token.scan(/.{1,6}/).join("-").upcase
    end
  end

  def generate_pkcs1_encrypted_key!
    if seed_key.bytesize > RSA_MAX_BYTE_SIZE
      errors.add :key, :byte_size_exceeded, message: "key exceeds maximum byte length (max size of #{RSA_MAX_BYTE_SIZE} bytes)"

      return
    end

    priv = OpenSSL::PKey::RSA.new account.private_key
    encrypted_key = priv.private_encrypt seed_key
    encoded_key = Base64.urlsafe_encode64 encrypted_key

    self.key = encoded_key
  end

  def generate_pkcs1_signed_key!(version:)
    priv = OpenSSL::PKey::RSA.new account.private_key
    res = nil

    case version
    when 1
      sig = priv.sign OpenSSL::Digest::SHA256.new, seed_key

      encoded_key = Base64.urlsafe_encode64 seed_key
      encoded_sig = Base64.urlsafe_encode64 sig

      res = "#{encoded_key}.#{encoded_sig}"
    when 2
      encoded_key = Base64.urlsafe_encode64 seed_key
      signing_data = "key/#{encoded_key}"
      sig = priv.sign OpenSSL::Digest::SHA256.new, signing_data
      encoded_sig = Base64.urlsafe_encode64 sig

      res = "#{signing_data}.#{encoded_sig}"
    end

    self.key = res
  end

  def generate_pkcs1_pss_signed_key!(version:)
    priv = OpenSSL::PKey::RSA.new account.private_key
    res = nil

    case version
    when 1
      sig = priv.sign_pss OpenSSL::Digest::SHA256.new, seed_key, salt_length: :max, mgf1_hash: "SHA256"

      encoded_key = Base64.urlsafe_encode64 seed_key
      encoded_sig = Base64.urlsafe_encode64 sig

      res = "#{encoded_key}.#{encoded_sig}"
    when 2
      encoded_key = Base64.urlsafe_encode64 seed_key
      signing_data = "key/#{encoded_key}"
      sig = priv.sign_pss OpenSSL::Digest::SHA256.new, signing_data, salt_length: :max, mgf1_hash: "SHA256"
      encoded_sig = Base64.urlsafe_encode64 sig

      res = "#{signing_data}.#{encoded_sig}"
    end

    self.key = res
  end

  def generate_jwt_rs256_key!
    priv = OpenSSL::PKey::RSA.new account.private_key
    payload = JSON.parse seed_key
    jwt = JWT.encode payload, priv, "RS256"

    self.key = jwt
  rescue JSON::GeneratorError,
         JSON::ParserError
    errors.add :key, :jwt_claims_invalid, message: "key is not a valid JWT claims payload (must be a valid JSON encoded string)"
  rescue JWT::InvalidPayload => e
    errors.add :key, :jwt_claims_invalid, message: "key is not a valid JWT claims payload (#{e.message.downcase})"
  end

  def generate_ed25519_signed_key!
    signing_key = Ed25519::SigningKey.new [account.ed25519_private_key].pack('H*')
    encoded_license_key = Base64.urlsafe_encode64 seed_key
    signing_data = "key/#{encoded_license_key}"
    sig = signing_key.sign signing_data
    encoded_sig = Base64.urlsafe_encode64 sig

    self.key = "#{signing_data}.#{encoded_sig}"
  end

  def enforce_active_licensed_user_limit_on_account!
    return unless account.trialing_or_free?

    active_licensed_user_count = account.active_licensed_user_count
    active_licensed_user_limit = account.plan.max_licenses ||
                                 account.plan.max_users

    return if active_licensed_user_count.nil? ||
              active_licensed_user_limit.nil?

    if active_licensed_user_count >= active_licensed_user_limit
      errors.add :account, :alu_limit_exceeded, message: "Your tier's active licensed user limit of #{active_licensed_user_limit.to_fs(:delimited)} has been reached for your account. Please upgrade to a paid tier and add a payment method at https://app.keygen.sh/billing."

      throw :abort
    end
  end
end
