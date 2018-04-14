_ = require 'lodash'
router = require 'exoid-router'
crypto = require 'crypto'

TimeService = require '../services/time'
EarnAction = require '../models/earn_action'
config = require '../config'

REEDEMABLE_ACTION_KEYS_FROM_CLIENT = ['visit', 'watchAd']

class EarnActionCtrl
  incrementByGroupIdAndAction: (options, {user}) ->
    {groupId, action, timestamp, successKey} = options
    if REEDEMABLE_ACTION_KEYS_FROM_CLIENT.indexOf(action) is -1
      router.throw {status: 400, info: 'cannot claim'}

    # if action is 'watchAd'
    #   shasum = crypto.createHmac 'md5', config.NATIVE_SORT_OF_SECRET
    #   shasum.update "#{timestamp}"
    #   compareKey = shasum.digest('hex')
    #   if not timestamp or not successKey or compareKey isnt successKey
    #     router.throw {status: 400, info: 'invalid'}

    EarnAction.completeActionByGroupIdAndUserId(
      groupId, user.id, action
    )

  getAllByGroupId: ({groupId}, {user}) ->
    Promise.all [
      EarnAction.getAllByGroupId groupId
      EarnAction.getAllTransactionsByUserIdAndGroupId(
        user.id, groupId
      )
    ]
    .then ([actions, transactions]) ->
      _.map actions, (action) ->
        action.transaction = _.find transactions, {action: action.action}
        action

module.exports = new EarnActionCtrl()
