-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2011 Alex Constandache
-- License     :  BSD3
-- Maintainer  :  alexander.the.average@gmail.com
-- Stability   :  alpha
-- Portability :  GHC only
--
-- This module implements Erlang-style actors 
-- (what Erlang calls processes). It does not implement 
-- network distribution (yet?).
-- An actor is parametrised by the type of messages it 
-- receives and the type of messages it sends.
--
-- Here is an example:
--
-- @
--act1 :: Actor 
--act1 = forever $ do
--    msg <- receive
--    me <- self
--    liftIO . putStrLn $ \"act1: received \" ++ (show num)
--    send addr (me, num + 1)
--
--act2 :: Int -> Address -> Actor 
--act2 n0 addr = do
--    send addr n0
--    forever $ do
--        (num, addr1) <- receive
--        liftIO . putStrLn $ \"act2: received \" ++ (show num)
--        send addr1 (num + 1)
--
--main = do
--    addr1 <- spawn act1
--    addr2 <- spawn $ act2 0 addr1
--    threadDelay 20000000
-- @
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
module Control.Concurrent.Actor (
  -- * Types
    Address
  , Message
  , Handler(..)
  , ActorM
  , Actor
  , ActorException
  -- * Actor actions
  , send
  , (◁)
  , (▷)
  , self
  , receive
  , receiveWithTimeout
  , handle
  , spawn
  , monitor
  , link
  ) where

import Control.Concurrent 
  ( forkIO
  , myThreadId
  , ThreadId
  )
import Control.Exception 
  ( Exception(..)
  , SomeException
  , catches
  , throwTo
  )
import qualified Control.Exception as E (Handler(..))
import Control.Concurrent.Chan 
  ( Chan
  , newChan
  , readChan
  , writeChan
  )
import Control.Concurrent.MVar 
  ( MVar
  , newMVar
  , modifyMVar_
  , withMVar
  )
import Control.Monad.Reader 
  ( ReaderT
  , runReaderT
  , asks
  , ask
  , liftIO
  )
import System.Timeout (timeout)
import Data.Dynamic
import Data.Set 
  ( Set
  , empty
  , insert
  , delete
  , elems
  )

-- | Exception raised by an actor on exit
data ActorException = ActorException ThreadId (Maybe SomeException) 
  deriving (Typeable, Show)

instance Exception ActorException

type Message = Dynamic

-- | The address of an actor, used to send messages 
data Address = Addr 
  { thId  :: ThreadId
  , ctxt  :: Context
  }

instance Eq Address where
    addr1 == addr2 = (thId addr1) == (thId addr2)

data Context = Ctxt 
  { mVar :: MVar (Set ThreadId)
  , chan :: Chan Message
  }

-- | The actor monad, just a reader monad on top of 'IO'.
type ActorM = ReaderT Context IO 

-- | The type of an actor. It is just a monadic action
-- in the 'ActorM' monad, returning ()
type Actor = ActorM ()

data Handler = forall m . (Typeable m) => Handler (m -> ActorM ())

-- | Used to obtain an actor's own address inside the actor
self :: ActorM Address
self = do
    c <- ask
    i <- liftIO myThreadId
    return $ Addr i c

-- | Receive a message inside the 'ActorM' monad. Blocks until
-- a message arrives if the mailbox is empty
receive :: ActorM Message
receive = do
    ch <- asks chan
    liftIO . readChan $ ch
    

-- | Same as receive, but times out after a specified 
-- amount of time and returns 'Nothing'
receiveWithTimeout :: Int -> ActorM (Maybe Message)
receiveWithTimeout n = do 
    ch <- asks chan 
    liftIO . timeout n . readChan $ ch

handle :: [Handler] -> Message -> ActorM ()
handle hs msg = mapM_ (exec msg) hs where
    exec m (Handler hdl) = case fromDynamic m of
        Just m' -> hdl m'
        Nothing -> return ()

-- | Sends a message from inside the 'ActorM' monad
send :: Address -> Message -> ActorM ()
send addr msg = do
    let ch = chan . ctxt $ addr
    liftIO . writeChan ch $ msg

-- | Infix form of 'send'
(◁) :: Address -> Message -> ActorM ()
(◁) = send
    
-- | Infix form of 'send' with the arguments flipped
(▷) :: Message -> Address -> ActorM ()
(▷) = flip send

-- | Spawns a new actor
spawn :: Actor -> IO Address
spawn act = do
    ch <- liftIO newChan
    mv <- newMVar empty
    let cx = Ctxt mv ch
    let orig = runReaderT act cx
        wrap = do
            orig `catches` [E.Handler actorExH, E.Handler someExH]
            me <- myThreadId
            forward (ActorException me Nothing) 
        actorExH :: ActorException -> IO ()
        actorExH e@(ActorException ti _) = do
            modifyMVar_ mv (\set -> return $ delete ti set)
            me  <- myThreadId
            let se = toException e
            forward (ActorException me (Just se))
        someExH :: SomeException -> IO ()
        someExH e = do
            me  <- myThreadId
            forward (ActorException me (Just e))
        forward :: ActorException -> IO ()
        forward e = do
            lset <- withMVar mv return
            mapM_ (flip throwTo $ e) (elems lset)
    ti <- forkIO wrap
    return $ Addr ti cx

-- | Monitors the actor at the specified address.
-- If an exception is raised in the monitored actor's 
-- thread, it is wrapped in an 'ActorException' and 
-- forwarded to the monitoring actor. If the monitored
-- actor terminates, an 'ActorException' is raised in
-- the monitoring Actor
monitor :: Address -> ActorM ()
monitor addr = do
    me <- liftIO myThreadId
    let mv = mVar. ctxt $ addr
    liftIO $ modifyMVar_ mv (return . insert me)

-- | Like `monitor`, but bi-directional
link :: Address -> ActorM ()
link addr = do
    monitor addr
    mv <- asks mVar
    let ti = thId addr
    liftIO $ modifyMVar_ mv (return . insert ti)
