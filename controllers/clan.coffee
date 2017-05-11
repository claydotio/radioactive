_ = require 'lodash'
router = require 'exoid-router'
Joi = require 'joi'

User = require '../models/user'
Clan = require '../models/clan'
GroupClan = require '../models/group_clan'
Group = require '../models/group'
Player = require '../models/player'
UserPlayer = require '../models/user_player'
Conversation = require '../models/conversation'
ClashRoyaleClanService = require '../services/clash_royale_clan'
ClashRoyaleKueService = require '../services/clash_royale_kue'
KueCreateService = require '../services/kue_create'
CacheService = require '../services/cache'
EmbedService = require '../services/embed'
r = require '../services/rethinkdb'
config = require '../config'

defaultEmbed = [
  EmbedService.TYPES.CLAN.PLAYERS
  EmbedService.TYPES.CLAN.IS_UPDATABLE
]

GAME_ID = config.CLASH_ROYALE_ID
TWELVE_HOURS_SECONDS = 12 * 3600
ONE_MINUTE_SECONDS = 60

class ClanCtrl
  getById: ({id}, {user}) ->
    Clan.getByClanIdAndGameId id, GAME_ID
    .then EmbedService.embed {embed: defaultEmbed}
    .then (clan) ->
      if clan?.creatorId is user.id
        Clan.sanitize null, clan
      else
        Clan.sanitizePublic null, clan

  claimById: ({id}, {user}) ->
    Clan.getByClanIdAndGameId id, GAME_ID
    .then (clan) ->
      unless clan
        router.throw {status: 404, info: 'clan not found'}

      if clan?.groupId
        router.throw {status: 400, info: 'clan already claimed'}

      # TODO: make sure api doesn't use cached version
      Promise.all [
        ClashRoyaleKueService.getClanByTag clan.clanId
        Player.getByUserIdAndGameId user.id, GAME_ID
      ]
      .then ([updatedClan, player]) ->
        # replace capital O with 0
        description = updatedClan?.description?.toUpperCase()
        isValid = clan?.code and description?.indexOf(clan?.code) isnt -1
        unless isValid
          router.throw {status: 400, info: 'unable to verify'}

        clanPlayer = _.find clan?.players, {playerId: player?.id}
        isLeader = clanPlayer?.role in ['coLeader', 'leader']
        unless isLeader
          router.throw {status: 400, info: 'must be at least co-leader'}

        Promise.all [
          GroupClan.updateByClanIdAndGameId id, GAME_ID, {creatorId: user.id}
          UserPlayer.updateByUserIdAndPlayerIdAndGameId(
            user.id
            player.id
            GAME_ID
            {isVerified: true}
          )
        ]

  createGroupById: ({id, groupName, clanPassword}, {user}) ->
    Clan.getByClanIdAndGameId id, GAME_ID
    .tap (clan) ->
      console.log clan
      if not clan?.creatorId or clan?.creatorId isnt user.id
        router.throw {status: 401, info: 'invalid permission'}

      unless clanPassword
        router.throw {status: 400, info: 'must specify a password'}

      unless groupName
        router.throw {status: 400, info: 'must specify a name'}

      clanPassword = clanPassword.trim()

      Group.create {
        name: groupName
        creatorId: user.id
        mode: 'private'
        userIds: [user.id]
        gameIds: [GAME_ID]
        clanIds: [clan.id]
        # TODO: remove? legacy
        gameData:
          "#{id}":
            clanId: clan.id
      }
      .tap (group) ->
        Conversation.create {
          groupId: group.id
          name: 'general'
          type: 'channel'
        }
      .tap (group) ->
        GroupClan.updateByClanIdAndGameId clan.id, GAME_ID, {
          password: clanPassword, groupId: group.id
        }

  joinById: ({id, clanPassword}, {user}) ->
    Promise.all [
      Clan.getByClanIdAndGameId id, GAME_ID
      Player.getByUserIdAndGameId user.id, GAME_ID
    ]
    .then ([clan, player]) ->
      clanPlayer = _.find clan?.players, {playerId: player?.id}
      unless clanPlayer
        router.throw {status: 401, info: 'not a clan member'}

      if not clanPassword or clanPassword isnt clan.password
        router.throw {status: 401, info: 'incorrect password'}

      Promise.all [
        Group.updateById clan.groupId,
          userIds: r.row('userIds').append(user.id).distinct()
        UserPlayer.updateByUserIdAndPlayerIdAndGameId(
          user.id
          player.id
          GAME_ID
          {isVerified: true}
        )
      ]


  search: ({clanId}, {user}) ->
    clanId = clanId.trim().toUpperCase()
                .replace '#', ''
                .replace /O/g, '0' # replace capital O with zero

    isValidTag = clanId.match /^[0289PYLQGRJCUV]+$/
    console.log 'search', clanId
    unless isValidTag
      router.throw {status: 400, info: 'invalid tag', ignoreLog: true}

    key = "#{CacheService.PREFIXES.PLAYER_SEARCH}:#{clanId}"
    CacheService.preferCache key, ->
      Clan.getByPlayerIdAndGameId clanId, config.CLASH_ROYALE_ID
      .then Clan.sanitizePublic
    , {expireSeconds: TWELVE_HOURS_SECONDS}

module.exports = new ClanCtrl()
