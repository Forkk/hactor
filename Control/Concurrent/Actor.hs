-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2014 Forkk
-- License     :  MIT
-- Maintainer  :  forkk@forkk.net
-- Stability   :  experimental
-- Portability :  GHC only (requires throwTo)
--
-- This module implements Erlang-style actors (what Erlang calls processes).
--
module Control.Concurrent.Actor
    (
    -- * Types
      ActorHandle
    , ActorMessage
    , MonadActor
    , ActorM
    -- * Sending Messages
    , send
    -- * Receiving Messages
    , receive
    , receiveMaybe
    , receiveSTM
    -- * Spawning Actors
    , spawnActor
    , runActor
    -- * Getting Information
    , self
    , actorThread
    ) where

import Control.Concurrent.Actor.Internal

