_ = require 'lodash'
assertNoneMissing = require 'assert-none-missing'

env = process.env

# REDIS_PORT = if env.IS_STAGING is '1' then 6378 else 6379 # for cluster
REDIS_PORT = 6379
DEV_USE_HTTPS = process.env.DEV_USE_HTTPS and process.env.DEV_USE_HTTPS isnt '0'

config =
  # hardcoded while we just have one game
  CLASH_ROYALE_ID: '319a9065-e3dc-4d02-ad30-62047716a88f'
  CLASH_ROYALE_TROPHIES_RECORD_ID: 'ed3b3643-039b-4a3f-9d44-0742b86e0a2c'
  CLASH_ROYALE_DONATIONS_RECORD_ID: '3b87da6c-7a2b-42c1-a59d-7354acaf80b0'
  CLASH_ROYALE_CLAN_CROWNS_RECORD_ID: 'aee6d338-2d6e-4b9a-af65-a48674bce3ef'
  CLASH_ROYALE_CLAN_DONATIONS_RECORD_ID: 'e3f646a8-d810-4df7-8cdd-ffaa1fb879e0'
  CLASH_ROYALE_CLAN_TROPHIES_RECORD_ID: '0135ddf8-7a24-4f40-b828-d43c39d6553c'
  MAIN_GROUP_ID: '73ed4af0-a2f2-4371-a893-1360d3989708' # TODO: remove?
  WITH_ZACK_GROUP_ID: 'e4495c00-977b-4632-8e7c-01b352401b4f' # TODO: remove?

  IS_POSTGRES: env.IS_POSTGRES or false

  VERBOSE: if env.VERBOSE then env.VERBOSE is '1' else true
  PORT: env.RADIOACTIVE_PORT or 50000
  ENV: env.DEBUG_ENV or env.NODE_ENV
  IS_STAGING: env.IS_STAGING is '1'
  JWT_ES256_PRIVATE_KEY: env.JWT_ES256_PRIVATE_KEY
  JWT_ES256_PUBLIC_KEY: env.JWT_ES256_PUBLIC_KEY
  JWT_ISSUER: 'exoid'
  DEV_USE_HTTPS: DEV_USE_HTTPS
  MAX_CPU: env.RADIOACTIVE_MAX_CPU or 1
  APN_CERT: env.RADIOACTIVE_APN_CERT
  APN_KEY: env.RADIOACTIVE_APN_KEY
  APN_PASSPHRASE: env.RADIOACTIVE_APN_PASSPHRASE
  GOOGLE_PRIVATE_KEY_JSON: env.GOOGLE_PRIVATE_KEY_JSON
  GOOGLE_API_KEY: env.GOOGLE_API_KEY
  GOOGLE_API_KEY_MYSTIC: env.GOOGLE_API_KEY_MYSTIC
  CARD_CODE_MAX_LENGTH: 9999999999
  PCG_SEED: env.RADIOACTIVE_PCG_SEED
  PT_UTC_OFFSET: -8
  IOS_BUNDLE_ID: 'com.clay.redtritium'
  DEALER_API_URL: env.DEALER_API_URL
  DEALER_SECRET: env.DEALER_SECRET
  CR_API_URL: env.CR_API_URL
  CR_API_SECRET: env.CR_API_SECRET
  RADIOACTIVE_API_URL: env.RADIOACTIVE_API_URL
  VAPID_SUBJECT: env.RADIOACTIVE_VAPID_SUBJECT
  VAPID_PUBLIC_KEY: env.RADIOACTIVE_VAPID_PUBLIC_KEY
  VAPID_PRIVATE_KEY: env.RADIOACTIVE_VAPID_PRIVATE_KEY
  STRIPE_SECRET_KEY: env.STRIPE_SECRET_KEY
  HONEYPOT_ACCESS_KEY: env.HONEYPOT_ACCESS_KEY
  CLASH_ROYALE_API_URL: 'https://api.clashroyale.com/v1'
  CLASH_ROYALE_API_KEY: env.CLASH_ROYALE_API_KEY
  GA_ID: env.RADIOACTIVE_GA_ID
  GOOGLE:
    CLIENT_ID: env.GOOGLE_CLIENT_ID
    CLIENT_SECRET: env.GOOGLE_CLIENT_SECRET
    REFRESH_TOKEN: env.GOOGLE_REFRESH_TOKEN
    REDIRECT_URL: 'urn:ietf:wg:oauth:2.0:oob'
  GMAIL:
    USER: env.GMAIL_USER
    PASS: env.GMAIL_PASS
  RETHINK:
    DB: env.RETHINK_DB or 'radioactive'
    HOST: env.RETHINK_HOST or 'localhost'
  POSTGRES:
    HOST: env.POSTGRES_HOST or 'localhost'
    USER: env.POSTGRES_USER or 'postgres'
    PASS: env.POSTGRES_PASS or 'password'
    DB: env.POSTGRES_DB or 'clash_royale'
  REDIS:
    PREFIX: 'radioactive'
    PORT: REDIS_PORT
    KUE_HOST: env.REDIS_KUE_HOST
    RADIOACTIVE_HOST: env.REDIS_RADIOACTIVE_HOST
    # NODES: if env.REDIS_CLUSTER_HOSTS \
    #        then _.map env.REDIS_CLUSTER_HOSTS.split(','), (host) ->
    #          {host, port: REDIS_PORT}
    #        else [env.REDIS_HOST]
  CDN_HOST: env.CDN_HOST
  SCYLLA:
    port: 9042
    CONTACT_POINTS: env.SCYLLA_CONTACT_POINTS.split(',')
  AWS:
    REGION: 'us-west-2'
    CDN_BUCKET: env.AWS_CDN_BUCKET
    ACCESS_KEY_ID: env.AWS_ACCESS_KEY_ID
    SECRET_ACCESS_KEY: env.AWS_SECRET_ACCESS_KEY
  ENVS:
    DEV: 'development'
    PROD: 'production'
    TEST: 'test'

assertNoneMissing config

module.exports = config
