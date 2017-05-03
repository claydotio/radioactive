Promise = require 'bluebird'
_ = require 'lodash'
request = require 'request-promise'
moment = require 'moment'

Player = require '../models/player'
PlayersDaily = require '../models/player_daily'
Clan = require '../models/clan'
Group = require '../models/group'
ClashRoyaleUserDeck = require '../models/clash_royale_user_deck'
ClashRoyaleDeck = require '../models/clash_royale_deck'
ClashRoyaleCard = require '../models/clash_royale_card'
ClashRoyaleTopPlayer = require '../models/clash_royale_top_player'
EmailService = require './email'
CacheService = require './cache'
GameRecord = require '../models/game_record'
PushNotificationService = require './push_notification'
ClashRoyaleKueService = require './clash_royale_kue'
Match = require '../models/clash_royale_match'
User = require '../models/user'
config = require '../config'

# for now we're not storing user deck info of players that aren't on starfire.
# should re-enable if we can handle the added load from it
ENABLE_ANON_USER_DECKS = false

MAX_TIME_TO_COMPLETE_MS = 60 * 30 * 1000 # 30min
PLAYER_DATA_STALE_TIME_S = 3600 * 12 # 12hr
PLAYER_MATCHES_STALE_TIME_S = 60 * 60 # 1 hour
# FIXME: temp fix so queue doesn't grow forever
MIN_TIME_BETWEEN_UPDATES_MS = 60 * 20 * 1000 # 20min
TWENTY_THREE_HOURS_S = 3600 * 23
SIX_HOURS_S = 3600 * 6
ONE_HOUR_SECONDS = 60
PLAYER_DATA_TIMEOUT_MS = 10000
PLAYER_MATCHES_TIMEOUT_MS = 5000
CLAN_TIMEOUT_MS = 1000
BATCH_REQUEST_SIZE = 50
GAME_ID = config.CLASH_ROYALE_ID
DEBUG = false

class ClashRoyalePlayer
  getMatchPlayerData: ({player, deckId}) ->
    {
      deckId: deckId
      crowns: player.crowns
      playerName: player.playerName
      playerTag: player.playerTag
      clanName: player.clanName
      clanTag: player.clanTag
      trophies: player.trophies
      chest: player.chest
    }

  createNewUserDecks: (matches, playerDiffs) ->
    userDecks = _.flatten _.map matches, ({player1, player2}) ->
      player1Tag = player1.playerTag
      player2Tag = player2.playerTag
      player1Player = playerDiffs.getCachedById player1Tag
      player2Player = playerDiffs.getCachedById player2Tag
      _.filter [
        if player1Player
          {
            playerId: player1Tag
            userIds: player1Player.userIds
            deckId: ClashRoyaleDeck.getDeckId player1.cardKeys
          }
        if player2Player
          {
            playerId: player2Tag
            userIds: player2Player.userIds
            deckId: ClashRoyaleDeck.getDeckId player2.cardKeys
          }
      ]
    userDecks = _.uniqBy userDecks, (obj) -> JSON.stringify obj
    # unique user deck per userId (not per playerId). create one for playerId
    # if no users exist yet (so it can be duplicated over to new account)
    start = Date.now()

    deckIdPlayerIds = _.map userDecks, (userDeck) ->
      _.pick userDeck, ['deckId', 'playerId']

    ClashRoyaleUserDeck.getAllByDeckIdPlayerIds deckIdPlayerIds
    .then (existingUserDecks) ->
      batchUserDecks = _.filter _.flatten _.map userDecks, (userDeck) ->
        {playerId, deckId, userIds} = userDeck

        hasUserIds = not _.isEmpty(userIds)
        if ENABLE_ANON_USER_DECKS and not hasUserIds and
            not _.find existingUserDecks, {deckId, playerId}
          return {
            deckId
            playerId
            isFavorited: true
          }
        else if hasUserIds
          _.map userIds, (userId) ->
            unless _.find existingUserDecks, {deckId, playerId, userId}
              return {
                deckId
                playerId
                userId
                isFavorited: true
              }
        else
          null
      ClashRoyaleUserDeck.batchCreate batchUserDecks

  createNewDecks: (matches, cards) ->
    deckKeys = _.uniq _.flatten _.map matches, ({player1, player2}) ->
      [
        ClashRoyaleDeck.getDeckId player1.cardKeys
        ClashRoyaleDeck.getDeckId player2.cardKeys
      ]
    ClashRoyaleDeck.getByIds deckKeys
    .then (existingDecks) ->
      newDecks = _.filter deckKeys, (key) ->
        not _.find existingDecks, {id: key}

      batchDecks = _.map newDecks, (keys) ->
        keysArray = keys.split('|')
        cardIds = _.map keysArray, (key) ->
          _.find(cards, {key})?.id
        {
          id: keys
          cardIds: cardIds
          name: 'Nameless'
        }
      ClashRoyaleDeck.batchCreate batchDecks

  incrementUserDecks: (batchUserDecks) ->
    Promise.all _.flatten _.map batchUserDecks, (userDecks, playerId) ->
      _.map userDecks, (changes, deckId) ->
        ClashRoyaleUserDeck.incrementAllByDeckIdAndPlayerId(
          deckId, playerId, changes
        )

  incrementDecks: (batchDecks) ->
    Promise.all _.map batchDecks, (changes, deckId) ->
      ClashRoyaleDeck.incrementAllById(
        deckId, changes
      )

  filterMatches: ({matches, player}) ->
    if DEBUG
      console.log 'filtering matches', processingM
    # only grab matches since the last update time
    matches = _.filter matches, (match) ->
      unless match
        return false
      {time, type} = match

      if player.data?.lastMatchTime
        lastMatchTime = new Date player.data.lastMatchTime
      else
        lastMatchTime = 0
      # the server time isn't 100% accurate, so +- 15 seconds
      type in ['ladder', 'classicChallenge', 'grandChallenge'] and
        new Date(time).getTime() > (new Date(lastMatchTime).getTime() + 15)

  # we should always block this for db writes/reads so the queue
  # properly throttles db access
  processMatches: ({matches, reqSynchronous, reqPlayers}) ->
    start = Date.now()
    matches = _.uniqBy matches, 'id'
    matches = _.orderBy matches, ['time'], ['asc']
    reqPlayerIds = _.map reqPlayers, 'playerId'

    Promise.map matches, (match) ->
      matchId = match.id
      Match.getById matchId, {preferCache: true}
      .then (existingMatch) ->
        if existingMatch then null else match
    .then _.filter
    .then (matches) =>
      if DEBUG
        console.log 'filtered matches: ' + matches.length + ' ' + reqPlayerIds

      cardsKey = CacheService.KEYS.CLASH_ROYALE_CARDS
      cards = CacheService.preferCache cardsKey, ->
        ClashRoyaleCard.getAll()
      , {expireSeconds: ONE_HOUR_SECONDS}

      # store diffs in here so we can update once after all the matches are
      # processed, instead of once per match
      playerIds = _.uniq _.flatten _.map matches, (match) ->
        [match.player1.playerTag, match.player2.playerTag]

      playerDiffs = new PlayerSplitsDiffs()
      # batch
      batchGameRecords = []
      batchMatches = []
      batchUserDecks = {}
      batchDecks = {}

      start = Date.now()

      # FIXME FIXME: updated playerDiff userId before passing to
      # createNewUserDecks, so it checks for that existing deck
      Promise.all [
        cards
        playerDiffs.setInitialDiffs playerIds, reqPlayerIds
      ]
      .then ([cards, initialDiffs]) =>
        # don't need to block for this
        # @createNewDecks matches, cards

        # (if reqSynchronous
        #   @createNewUserDecks matches, playerDiffs
        # else
        #   Promise.resolve null) # don't block
        stepStart = Date.now()
        Promise.all [
          @createNewUserDecks matches, playerDiffs
          .catch (err) ->
            console.log 'user decks create postgres err', err
          @createNewDecks matches, cards
          .catch (err) ->
            console.log 'decks create postgres err', err
        ]
        .then =>
          # needs to be each for streak to work
          Promise.each matches, (match, i) =>
            matchId = match.id

            player1Tag = match.player1.playerTag
            player2Tag = match.player2.playerTag

            # prefer from cached diff obj
            # (that has been modified for stats, winStreak, etc...)
            player1Player = playerDiffs.getCachedById player1Tag
            player2Player = playerDiffs.getCachedById player2Tag

            deck1Id = ClashRoyaleDeck.getDeckId match.player1.cardKeys
            deck2Id = ClashRoyaleDeck.getDeckId match.player2.cardKeys

            deck1CardIds = _.map match.player1.cardKeys, (key) ->
              _.find(cards, {key})?.id
            deck2CardIds = _.map match.player2.cardKeys, (key) ->
              _.find(cards, {key})?.id

            type = match.type

            player1UserIds = player1Player?.userIds
            player2UserIds = player2Player?.userIds

            stepStart = Date.now()
            player1Won = match.player1.crowns > match.player2.crowns
            player2Won = match.player2.crowns > match.player1.crowns

            player1Diff = {
              lastMatchesUpdateTime: new Date()
              data:
                lastMatchTime: new Date(match.time)
            }
            if match.type is 'ladder'
              player1Diff.data.trophies = match.player1.trophies
            playerDiffs.setDiffById player1Tag, player1Diff

            player2Diff = {
              lastMatchesUpdateTime: new Date()
              data:
                lastMatchTime: new Date(match.time)
            }
            if match.type is 'ladder'
              player2Diff.data.trophies = match.player2.trophies
            playerDiffs.setDiffById player2Tag, player2Diff

            playerDiffs.incById {
              id: player1Tag
              field: 'crownsEarned'
              amount: match.player1.crowns
              type: type
            }
            playerDiffs.incById {
              id: player1Tag
              field: 'crownsLost'
              amount: match.player2.crowns
              type: type
            }

            playerDiffs.incById {
              id: player2Tag
              field: 'crownsEarned'
              amount: match.player2.crowns
              type: type
            }
            playerDiffs.incById {
              id: player2Tag
              field: 'crownsLost'
              amount: match.player1.crowns
              type: type
            }

            if player1Won
              winningDeckId = deck1Id
              losingDeckId = deck2Id
              winningDeckCardIds = deck1CardIds
              losingDeckCardIds = deck2CardIds
              deck1State = 'wins'
              deck2State = 'losses'

              playerDiffs.incById {id: player1Tag, field: 'wins', type: type}
              playerDiffs.incById {
                id: player1Tag, field: 'currentWinStreak', type: type
              }
              playerDiffs.setSplitStatById {
                id: player1Tag, field: 'currentLossStreak'
                value: 0, type: type
              }

              playerDiffs.incById {
                id: player2Tag, field: 'losses', type: type
              }
              playerDiffs.incById {
                id: player2Tag, field: 'currentLossStreak', type: type
              }
              playerDiffs.setSplitStatById {
                id: player2Tag, field: 'currentWinStreak'
                value: 0, type: type
              }
            else if player2Won
              winningDeckId = deck2Id
              losingDeckId = deck1Id
              winningDeckCardIds = deck2CardIds
              losingDeckCardIds = deck1CardIds
              deck1State = 'losses'
              deck2State = 'wins'

              playerDiffs.incById {id: player2Tag, field: 'wins', type: type}
              playerDiffs.incById {
                id: player2Tag, field: 'currentWinStreak', type: type
              }
              playerDiffs.setSplitStatById {
                id: player2Tag, field: 'currentLossStreak'
                value: 0, type: type
              }

              playerDiffs.incById {
                id: player1Tag, field: 'losses', type: type
              }
              playerDiffs.incById {
                id: player1Tag, field: 'currentLossStreak', type: type
              }
              playerDiffs.setSplitStatById {
                id: player1Tag, field: 'currentWinStreak'
                value: 0, type: type
              }
            else
              winningDeckId = null
              losingDeckId = null
              deck1State = 'draws'
              deck2State = 'draws'

              playerDiffs.incById {id: player1Tag, field: 'draws', type: type}
              playerDiffs.setSplitStatById {
                id: player1Tag, field: 'currentWinStreak'
                value: 0, type: type
              }
              playerDiffs.setSplitStatById {
                id: player1Tag, field: 'currentLossStreak'
                value: 0, type: type
              }

              playerDiffs.incById {id: player2Tag, field: 'draws', type: type}
              playerDiffs.setSplitStatById {
                id: player2Tag, field: 'currentWinStreak'
                value: 0, type: type
              }
              playerDiffs.setSplitStatById {
                id: player2Tag, field: 'currentLossStreak'
                value: 0, type: type
              }

            # player 1
            playerDiffs.setStreak {
              id: player1Tag, maxField: 'maxWinStreak'
              currentField: 'currentWinStreak', type: type
            }
            playerDiffs.setStreak {
              id: player1Tag, maxField: 'maxLossStreak'
              currentField: 'currentLossStreak', type: type
            }

            # player 2
            playerDiffs.setStreak {
              id: player2Tag, maxField: 'maxWinStreak'
              currentField: 'currentWinStreak', type: type
            }
            playerDiffs.setStreak {
              id: player2Tag, maxField: 'maxLossStreak'
              currentField: 'currentLossStreak', type: type
            }

            # for records (graph)
            scaledTime = GameRecord.getScaledTimeByTimeScale(
              'minute', moment(match.time)
            )

            prefix = CacheService.PREFIXES.CLASH_ROYALE_MATCHES_ID
            key = "#{prefix}:#{matchId}"
            matchObj = {
              id: matchId
              arena: match.arena
              league: match.league
              type: match.type
              player1Id: match.player1.playerTag
              player2Id: match.player2.playerTag
              # player1UserIds: player1UserIds
              # player2UserIds: player2UserIds
              winningDeckId: winningDeckId
              losingDeckId: losingDeckId
              winningCardIds: winningDeckCardIds
              losingCardIds: losingDeckCardIds
              player1Data: @getMatchPlayerData {
                player: match.player1, deck: deck1Id
              }
              player2Data: @getMatchPlayerData {
                player: match.player2, deck: deck2Id
              }
              time: new Date(match.time)
            }
            batchMatches.push matchObj

            if type is 'ladder'
              # graphs p1
              _.map player1UserIds, (userId) ->
                batchGameRecords.push {
                  userId: userId
                  playerId: player1Tag
                  gameRecordTypeId: config.CLASH_ROYALE_TROPHIES_RECORD_ID
                  scaledTime
                  value: match.player1.trophies
                }
              # graphs p2
              _.map player2UserIds, (userId) ->
                batchGameRecords.push {
                  userId: userId
                  playerId: player2Tag
                  gameRecordTypeId: config.CLASH_ROYALE_TROPHIES_RECORD_ID
                  scaledTime
                  value: match.player2.trophies
                }

            player1IsRequesting = reqPlayerIds.indexOf(player1Tag) isnt -1
            player2IsRequesting = reqPlayerIds.indexOf(player2Tag) isnt -1
            player1HasUserIds = not _.isEmpty player1Player?.userIds
            player2HasUserIds = not _.isEmpty player2Player?.userIds

            # don't need to block for any of these
            CacheService.set key, matchObj, {expireSeconds: SIX_HOURS_S}

            if player1HasUserIds or ENABLE_ANON_USER_DECKS
              batchUserDecks[player1Tag] ?= {}
              batchUserDecks[player1Tag][deck1Id] ?= {
                wins: 0, losses: 0, draws: 0
              }
              batchUserDecks[player1Tag][deck1Id][deck1State] += 1

              batchDecks[deck1Id] ?= {wins: 0, losses: 0, draws: 0}
              batchDecks[deck1Id][deck1State] += 1

            if player2HasUserIds or ENABLE_ANON_USER_DECKS
              batchUserDecks[player2Tag] ?= {}
              batchUserDecks[player2Tag][deck2Id] ?= {
                wins: 0, losses: 0, draws: 0
              }
              batchUserDecks[player2Tag][deck2Id][deck2State] += 1

              batchDecks[deck1Id] ?= {wins: 0, losses: 0, draws: 0}
              batchDecks[deck1Id][deck1State] += 1

        .then =>
          # # don't need to block
          # Match.batchCreate batchMatches

          # batchPromise = Promise.all [
          #   GameRecord.batchCreate batchGameRecords
          #   @incrementUserDecks batchUserDecks
          #   @incrementDecks batchDecks
          # ]
          #
          # stepStart = Date.now()
          # if reqSynchronous
          #   batchPromise
          # else
          #   null
          Promise.all [
            Match.batchCreate batchMatches
            .catch (err) ->
              console.log 'match create postgres err', err
            GameRecord.batchCreate batchGameRecords
            .catch (err) ->
              console.log 'gamerecord create postgres err', err
            @incrementUserDecks batchUserDecks
            .catch (err) ->
              console.log 'inc user decks postgres err', err
            @incrementDecks batchDecks
            .catch (err) ->
              console.log 'inc decks postgres err', err
          ]

        .then ->
          {playerDiffs: playerDiffs.getAll()}

  # morph api format to our format
  getPlayerFromPlayerData: ({playerData}) ->
    {
      currentDeck: playerData.currentDeck
      trophies: playerData.trophies
      name: playerData.name
      clan: if playerData.clan
      then { \
        tag: playerData.clan.tag, \
        name: playerData.clan.name, \
        badge: playerData.clan.badge
      }
      else null
      level: playerData.level
      arena: playerData.arena
      league: playerData.league
      chestCycle: playerData.chestCycle
      stats: _.merge playerData.stats, {
        games: playerData.games
        tournamentGames: playerData.tournamentGames
        wins: playerData.wins
        losses: playerData.losses
        currentStreak: playerData.currentStreak
      }
    }

  processUpdatePlayerMatches: ({matches, isBatched, tag, reqSynchronous}) =>
    if _.isEmpty matches
      return Promise.resolve null

    if isBatched
      tags = _.map matches, 'tag'
    else
      tags = [tag]

    start = Date.now()
    filteredMatches = null

    # get before update so we have accurate lastMatchTime
    Player.getAllByPlayerIdsAndGameId tags, GAME_ID
    .then (players) =>
      if isBatched
        filteredMatches = _.flatten _.map(players, (player) =>
          chunkMatches = _.find(matches, {tag: player.playerId})?.matches
          @filterMatches {matches: chunkMatches, player}
        )
      else
        filteredMatches = @filterMatches {matches, player: players[0]}

      @processMatches {
        matches: filteredMatches, reqPlayers: players, reqSynchronous
      }
    .then ({playerDiffs}) ->
      # no matches processed means no player diffs
      playerDiffs.all[tag] = _.defaults {
        lastMatchesUpdateTime: new Date()
      }, playerDiffs.all[tag]
      playerDiffs.day[tag] = _.defaults {
        lastMatchesUpdateTime: new Date()
      }, playerDiffs.day[tag]

      playerIds = _.keys playerDiffs.all
      # combine into 1 query for inserts instead of update to 25
      {inserts, updates} = _.reduce playerDiffs.all, (obj, diff, playerId) ->
        if diff.id
          obj.updates[playerId] = diff
        else
          obj.inserts.push _.defaults({playerId, gameId: GAME_ID}, diff)
        obj
      , {inserts: [], updates: {}}
      playerInserts = inserts
      playerUpdates = updates

      {inserts, updates} = _.reduce playerDiffs.day, (obj, diff, playerId) ->
        if diff.id
          obj.updates[playerId] = diff
        else
          obj.inserts.push _.defaults({playerId, gameId: GAME_ID}, diff)
        obj
      , {inserts: [], updates: {}}
      playersDailyInserts = inserts
      playersDailyUpdates = updates

      Promise.all [
        Player.batchCreate playerInserts
        Promise.all _.map playerUpdates, (diff, playerId) ->
          Player.updateByPlayerIdAndGameId playerId, GAME_ID, diff
        PlayersDaily.batchCreate playersDailyInserts
        Promise.all _.map playersDailyUpdates, (diff, playerId) ->
          PlayersDaily.updateByPlayerIdAndGameId playerId, GAME_ID, diff
      ]
      # kue doesn't complete with object response? needs str/empty?
      .then ->
        if DEBUG
          console.log(
            'match processing time', Date.now() - start
            isBatched, filteredMatches?.length
          )
        undefined


  updatePlayerData: ({userId, playerData, tag}) =>
    if DEBUG
      console.log 'update player data', tag
    unless tag and playerData
      return Promise.resolve null

    diff = {
      lastUpdateTime: new Date()
      playerId: tag
      data: @getPlayerFromPlayerData {playerData}
    }

    start = Date.now()

    (if playerData?.clan?.tag
      Clan.getByClanIdAndGameId playerData.clan.tag, GAME_ID, {
        preferCache: true
      }
    else
      Promise.resolve null)
    .then (clan) ->
      start = Date.now()
      if clan
        return clan
      else if playerData?.clan?.tag
        ClashRoyaleKueService.refreshByClanId playerData.clan.tag
        .timeout CLAN_TIMEOUT_MS
        .catch -> null
    .then (clan) ->
      start = Date.now()
      diff.clanId = clan?.id

      start = Date.now()
      Player.upsertByPlayerIdAndGameId tag, GAME_ID, diff, {userId}
      .catch (err) ->
        console.log 'err', err
        null

  updateStalePlayerMatches: ({force} = {}) ->
    Player.getStaleByGameId GAME_ID, {
      type: 'matches'
      staleTimeS: if force then 0 else PLAYER_MATCHES_STALE_TIME_S
    }
    .map ({playerId}) -> playerId
    .then (playerIds) ->
      if DEBUG
        console.log 'stalematch', playerIds.length, new Date()
      Player.updateByPlayerIdsAndGameId playerIds, GAME_ID, {
        lastMatchesUpdateTime: new Date()
      }
      playerIdChunks = _.chunk playerIds, BATCH_REQUEST_SIZE
      Promise.map playerIdChunks, (playerIds) ->
        tagsStr = playerIds.join ','
        request "#{config.CR_API_URL}/players/#{tagsStr}/games", {
          json: true
          qs:
            # 5 seems to be the sweet spot. 10 slows down new users too much
            chunkValue: 5 # send us back 5 users' matches at a time
            callbackUrl:
              "#{config.RADIOACTIVE_API_URL}/clashRoyaleAPI/updatePlayerMatches"
        }
        .catch (err) ->
          console.log 'err stalePlayerMatches', err

  updateStalePlayerData: ({force} = {}) ->
    Player.getStaleByGameId GAME_ID, {
      type: 'data'
      staleTimeS: if force then 0 else PLAYER_DATA_STALE_TIME_S
    }
    .map ({playerId}) -> playerId
    .then (playerIds) ->
      if DEBUG
        console.log 'staledata', playerIds.length, new Date()
      Player.updateByPlayerIdsAndGameId playerIds, GAME_ID, {
        lastUpdateTime: new Date()
      }
      playerIdChunks = _.chunk playerIds, BATCH_REQUEST_SIZE
      Promise.map playerIdChunks, (playerIds) ->
        tagsStr = playerIds.join ','
        request "#{config.CR_API_URL}/players/#{tagsStr}", {
          json: true
          qs:
            callbackUrl:
              "#{config.RADIOACTIVE_API_URL}/clashRoyaleAPI/updatePlayerData"
        }
        .catch (err) ->
          console.log 'err stalePlayerData', err

  processUpdatePlayerData: ({userId, tag, playerData, isDaily}) =>
    unless tag
      console.log 'tag doesn\'t exist updateplayerdata'
      return Promise.resolve null
    @updatePlayerData {userId, tag, playerData}
    .then (player) ->
      if isDaily
        key = CacheService.PREFIXES.USER_DAILY_DATA_PUSH + ':' + tag
        CacheService.runOnce key, ->
          Promise.all [
            Player.getByPlayerIdAndGameId tag, GAME_ID
            PlayersDaily.getByPlayerIdAndGameId tag, GAME_ID
          ]
          .then ([player, playersDaily]) ->
            if player and playersDaily?.data
              splits = playersDaily.data.splits
              stats = _.reduce splits, (aggregate, split, gameType) ->
                aggregate.wins += split.wins
                aggregate.losses += split.losses
                aggregate
              , {wins: 0, losses: 0}
              PlayersDaily.deleteById playersDaily.id
              Promise.map player.userIds, User.getById
              .map (user) ->
                if stats.wins > 0 or stats.losses > 0
                  PushNotificationService.send user, {
                    title: 'Daily recap'
                    type: PushNotificationService.TYPES.DAILY_RECAP
                    url: "https://#{config.SUPERNOVA_HOST}"
                    text: "#{stats.wins} wins, #{stats.losses} losses.
                          Post in chat what else you want to see in
                          the recap :)"
                    data: {path: '/'}
                  }
              null
        , {expireSeconds: TWENTY_THREE_HOURS_S}
  getTopPlayers: ->
    request "#{config.CR_API_URL}/players/top", {json: true}

  updateTopPlayers: =>
    if config.ENV is config.ENVS.DEV
      return
    @getTopPlayers().then (topPlayers) ->
      Promise.map topPlayers, (player, index) ->
        rank = index + 1
        playerId = player.playerTag
        Player.getByPlayerIdAndGameId playerId, GAME_ID
        .then (existingPlayer) ->
          if existingPlayer?.verifiedUserId
            Player.updateById existingPlayer.id, {
              data:
                trophies: player.trophies
                name: player.name
            }
          else
            User.create {}
            .then ({id}) ->
              userId = id
              Promise.all [
                ClashRoyaleUserDeck.duplicateByPlayerId playerId, userId
                GameRecord.duplicateByPlayerId playerId, userId
                Player.upsertByPlayerIdAndGameId playerId, GAME_ID, {
                  verifiedUserId: userId
                }, {userId}
              ]
              .then ->
                ClashRoyaleKueService.refreshByPlayerTag playerId, {
                  userId: userId, priority: 'normal'
                }

        .then ->
          ClashRoyaleTopPlayer.upsertByRank rank, {
            playerId: playerId
          }


class PlayerSplitsDiffs
  constructor: ->
    @playerDiffs = {all: {}, day: {}}

  setInitialDiffs: (playerIds, reqPlayerIds) =>
    Promise.all [
      Player.getAllByPlayerIdsAndGameId playerIds, GAME_ID
      PlayersDaily.getAllByPlayerIdsAndGameId playerIds, GAME_ID
    ]
    .then ([players, playersDaily]) =>
      _.map playerIds, (playerId) =>
        player = _.find players, {playerId}
        # only process existing players
        if player?.hasUserId or reqPlayerIds.indexOf(playerId) isnt -1
          @playerDiffs['all'][playerId] = _.defaultsDeep player, {
            data: {splits: {}}, playerId: playerId
          }

          playerDaily = _.find playersDaily, {playerId}
          @playerDiffs['day'][playerId] = _.defaultsDeep playerDaily, {
            data: {splits: {}}, playerId: playerId
          }

  getAll: =>
    @playerDiffs

  getCachedById: (playerId) =>
    @playerDiffs['all'][playerId]

  getCachedSplits: ({id, type, set}) =>
    unless @playerDiffs[set][id]
      return
    splits = @playerDiffs[set][id].data.splits[type]
    @playerDiffs[set][id].data.splits[type] = _.defaults splits, {
      currentWinStreak: 0
      currentLossStreak: 0
      maxWinStreak: 0
      maxLossStreak: 0
      crownsEarned: 0
      crownsLost: 0
      wins: 0
      losses: 0
      draws: 0
    }
    @playerDiffs[set][id].data.splits[type]

  getFieldById: ({id, field, type, set}) =>
    unless @playerDiffs[set][id]
      return
    @getCachedSplits({id, type, set})[field]

  incById: ({id, field, type, amount}) =>
    amount ?= 1
    _.map @playerDiffs, (diffs, set) =>
      @getCachedSplits({id, type, set})?[field] += amount

  setSplitStatById: ({id, field, type, value, set}) =>
    if set
      @getCachedSplits({id, type, set})?[field] = value
    else
      _.map @playerDiffs, (diffs, set) =>
        @getCachedSplits({id, type, set})?[field] = value

  setDiffById: (id, diff) =>
    _.map @playerDiffs, (diffs, set) =>
      unless @playerDiffs[set][id]
        return
      @playerDiffs[set][id] = _.merge @playerDiffs[set][id], diff

  setStreak: ({id, type, maxField, currentField}) =>
    _.map @playerDiffs, (diffs, set) =>
      max = @getFieldById {id, field: maxField, type, set}
      current = @getFieldById {id, field: currentField, type, set}
      if current > max
        @setSplitStatById {
          id: id, field: maxField
          value: current, type: type, set: set
        }

module.exports = new ClashRoyalePlayer()
