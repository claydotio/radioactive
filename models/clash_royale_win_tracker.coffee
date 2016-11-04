_ = require 'lodash'
Promise = require 'bluebird'
uuid = require 'node-uuid'

r = require '../services/rethinkdb'
config = require '../config'

module.exports = class ClashRoyaleWinTrackerModel
  constructor: ->
    table = @RETHINK_TABLES[0].name
    if table is 'clash_royale_decks'
      @timeFrame = 3600 * 24 * 14
    else
      @timeFrame = 3600 * 24 * 7

  getRank: ({thisWeekPopularity, lastWeekPopularity}) =>
    r.table @RETHINK_TABLES[0].name
    .filter(
      r.row(
        if thisWeekPopularity? \
        then 'thisWeekPopularity'
        else 'lastWeekPopularity'
      )
      .gt(
        if thisWeekPopularity? \
        then thisWeekPopularity
        else  lastWeekPopularity
      )
    )
    .count()
    .run()
    .then (rank) -> rank + 1

  updateWinsAndLosses: =>
    Promise.all [
      @getAll {limit: false}
      @getWinsAndLosses()
      @getWinsAndLosses({timeOffset: @timeFrame})
    ]
    .then ([items, thisWeek, lastWeek]) =>
      Promise.map items, (item) =>
        thisWeekItem = _.find thisWeek, {id: item.id}
        lastWeekItem = _.find lastWeek, {id: item.id}
        thisWeekWins = thisWeekItem?.wins or 0
        thisWeekLosses = thisWeekItem?.losses or 0
        thisWeekPopularity = thisWeekWins + thisWeekLosses
        lastWeekWins = lastWeekItem?.wins or 0
        lastWeekLosses = lastWeekItem?.losses or 0
        lastWeekPopularity = lastWeekWins + lastWeekLosses

        @updateById item.id, {
          thisWeekPopularity: thisWeekPopularity
          lastWeekPopularity: lastWeekPopularity
          timeRanges:
            thisWeek:
              thisWeekPopularity: thisWeekPopularity
              verifiedWins: thisWeekWins
              verifiedLosses: thisWeekLosses
            lastWeek:
              lastWeekPopularity: lastWeekPopularity
              verifiedWins: lastWeekWins
              verifiedLosses: lastWeekLosses
        }
        .then ->
          {id: item.id, thisWeekPopularity, lastWeekPopularity}
      , {concurrency: 10}
      .then (updates) =>
        Promise.map items, ({id}) =>
          {thisWeekPopularity, lastWeekPopularity} = _.find updates, {id}
          Promise.all [
            @getRank {thisWeekPopularity}
            @getRank {lastWeekPopularity}
          ]
          .then ([thisWeekRank, lastWeekRank]) =>
            @updateById id,
              timeRanges:
                thisWeek:
                  rank: thisWeekRank
                lastWeek:
                  rank: lastWeekRank
        , {concurrency: 10}

  getWinsAndLosses: ({timeOffset} = {}) =>
    timeOffset ?= 0
    Promise.all [@getWins({timeOffset}), @getLosses({timeOffset})]
    .then ([wins, losses]) ->
      Promise.map wins, ({id, count}) ->
        {id, wins: count, losses: _.find(losses, {id})?.count}

  getWins: ({timeOffset}) =>
    r.db('radioactive').table('clash_royale_matches')
    .between(
      r.now().sub(timeOffset + @timeFrame)
      r.now().sub(timeOffset)
      {index: 'time'}
    )
    .map((match) =>
      table = @RETHINK_TABLES[0].name
      if table is 'clash_royale_decks'
        key1 = [match('deck1Id')]
        key2 = [match('deck2Id')]
      else
        key1 = match('deck1CardIds')
        key2 = match('deck2CardIds')
      return r.branch(
        match('deck1Score').gt(match('deck2Score')) # if
        key1
        match('deck2Score').gt(match('deck1Score')) # else if
        key2
        [] # else
      )
    )
    .concatMap((items) ->
      return items
    )
    .group((itemId) -> return itemId)
    .count()
    .run()
    .map ({group, reduction}) -> {id: group, count: reduction}

  getLosses: ({timeOffset}) =>
    r.db('radioactive').table('clash_royale_matches')
    .between(
      r.now().sub(timeOffset + @timeFrame)
      r.now().sub(timeOffset)
      {index: 'time'}
    )
    .map((match) =>
      table = @RETHINK_TABLES[0].name
      if table is 'clash_royale_decks'
        key1 = [match('deck1Id')]
        key2 = [match('deck2Id')]
      else
        key1 = match('deck1CardIds')
        key2 = match('deck2CardIds')
      return r.branch(
        match('deck1Score').lt(match('deck2Score')) # if
        key1
        match('deck2Score').lt(match('deck1Score')) # else if
        key2
        [] # else
      )
    )
    .concatMap((items) ->
      return items
    )
    .group((itemId) -> return itemId)
    .count()
    .run()
    .map ({group, reduction}) -> {id: group, count: reduction}

  incrementById: (id, state) =>
    if state is 'win'
      diff = {
        wins: r.row('wins').add(1)
      }
    else if state is 'loss'
      diff = {
        losses: r.row('losses').add(1)
      }
    else if state is 'draw'
      diff = {
        draws: r.row('draws').add(1)
      }
    else
      diff = {}

    r.table @RETHINKDB_TABLES[0].name
    .get id
    .update diff
    .run()
