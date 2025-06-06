services:
  - type: web
    name: keygen-api
    env: docker
    repo: https://github.com/snowballons/keygen-api.git
    branch: main
    docker:
      dockerfilePath: ./Dockerfile
    preDeployCommand: rails db:migrate
    envVars:
      - key: DATABASE_URL
        fromDatabase:
          name: keygen-db
          property: connectionString
      - key: REDIS_URL
        fromService:
          type: redis
          name: keygen-cache
          property: connectionString
      - key: KEYGEN_MODE
        value: singleplayer
      - key: KEYGEN_HOST
        value: https://keygen-api.onrender.com
      - key: PORT
        value: 3000
      - key: RAILS_ENV
        value: production

  - type: database
    name: keygen-db
    databaseType: postgresql
    plan: starter
    ipAllowList: [] # Allow external access if needed
    region: oregon
    postgresVersion: 15

  - type: redis
    name: keygen-cache
    plan: free
    region: oregon
