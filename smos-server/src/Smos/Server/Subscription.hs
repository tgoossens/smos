{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Server.Subscription where

import Control.Monad.Reader
import qualified Data.Set as S
import Servant
import Smos.API
import Smos.Server.DB
import Smos.Server.Env
import Smos.Server.OptParse.Types

getSubscriptionStatusForUser :: Username -> ServerHandler SubscriptionStatus
getSubscriptionStatusForUser username = do
  mMonetisation <- asks serverEnvMonetisationSettings
  case mMonetisation of
    Nothing -> pure NoSubscriptionNecessary
    Just MonetisationSettings {..} -> do
      mAdmin <- asks serverEnvAdmin
      if mAdmin == Just username
        then pure NoSubscriptionNecessary
        else do
          if S.member username monetisationSetFreeloaders
            then pure NoSubscriptionNecessary
            else do
              mUser <- runDB $ getBy $ UniqueUsername username
              case mUser of
                Nothing -> throwError $ err404 {errBody = "User not found."}
                Just (Entity uid _) -> do
                  mSubscription <- runDB $ getBy $ UniqueSubscriptionUser uid
                  pure $ case mSubscription of
                    Nothing -> NotSubscribed
                    Just (Entity _ Subscription {..}) -> SubscribedUntil subscriptionEnd
