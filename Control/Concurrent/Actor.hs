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
--act1 :: Actor Int Int
--act1 = forever $ do
--    (num, addr) <- receive
--    liftIO . putStrLn $ \"act1: received \" ++ (show num)
--    send addr (num + 1)
--
--act2 :: Int -> Address Int Int -> Actor Int Int
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
module Control.Concurrent.Actor (
  -- * Types
    Address
  , ActorM
  , Actor
  , ActorException
  -- * Actor actions
  , send
  , (◁)
  , (▷)
  , receive
  , receiveWithTimeout
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
  , Handler(..)
  )
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
  , liftIO
  )
import Control.Monad (liftM)
import System.Timeout (timeout)
import Data.Set 
  ( Set
  , empty
  , insert
  , delete
  , elems
  )
import Data.Typeable (Typeable)


-- | Exception raised by an actor on exit
data ActorException = ActorException ThreadId (Maybe SomeException) 
  deriving (Typeable, Show)

instance Exception ActorException

data Dialog a b = Dia 
  { message :: a 
  , address :: Address b a
  }

diaToPair :: Dialog a b -> (a, Address b a)
diaToPair d = (message d, address d)

-- | The address of an actor that accepts messages of
-- type /a/ and sends messages of type /b/ 
data Address a b = Addr 
  { aTId  :: ThreadId
  , aMVar :: MVar (Set ThreadId)
  , aChan :: Chan (Dialog a b) 
  }

instance Eq (Address a b) where
    addr1 == addr2 = (aTId addr1) == (aTId addr2)

data Context a b = Ctxt 
  { cMVar :: MVar (Set ThreadId)
  , cChan :: Chan (Dialog a b)
  }

-- | The actor monad, just a reader monad on top of 'IO'.
-- It carries information about an actor's mailbox, which is
-- hidden from the library's users.
type ActorM a b = ReaderT (Context a b) IO 

-- | The type of an actor accepting messages of type /a/ and
-- returning messages of type /b/. It is just a monadic action
-- in the 'ActorM' monad, returning ()
type Actor a b = ActorM a b ()


self :: ActorM a b (Address a b)
self = do
    ch <- asks cChan
    mv <- asks cMVar
    ti <- liftIO myThreadId
    return $ Addr ti mv ch

-- | Receive a message inside the 'ActorM' monad. Blocks until
-- a message arrives if the mailbox is empty
receive :: ActorM a b (a, Address b a)
receive = do
    ch <- asks cChan
    let pair = liftM diaToPair $ readChan ch
    liftIO pair

-- | Same as receive, but times out after a specified 
-- amount of time and returns 'Nothing'
receiveWithTimeout :: Int -> ActorM a b (Maybe (a, Address b a))
receiveWithTimeout n = do 
   ch <- asks cChan 
   let mpair = timeout n . liftM diaToPair $ readChan ch
   liftIO mpair

-- | Sends a message from inside the 'ActorM' monad
send :: Address a b -> a -> ActorM b a ()
send addr msg = do
    me <- self 
    let ch = aChan addr
    liftIO $ writeChan ch (Dia msg me)

-- | Infix form of 'send'
(◁) :: Address a b -> a -> ActorM b a ()
(◁) = send
    
-- | Infix form of 'send' with the arguments flipped
(▷) :: a -> Address a b -> ActorM b a ()
(▷) = flip send

-- | Spawns a new actor
spawn :: Actor a b -> IO (Address a b)
spawn act = do
    ch <- liftIO newChan
    mv <- newMVar empty
    let orig = runReaderT act (Ctxt mv ch)
        wrap = do
            orig `catches` [Handler actorExH, Handler someExH]
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
        forward e = do
            lset <- withMVar mv return
            mapM_ (flip throwTo $ e) (elems lset)
    ti <- forkIO wrap
    return $ Addr ti mv ch

-- | Monitors the actor at the specified address.
-- If an exception is raised in the monitored actor's 
-- thread, it is wrapped in an 'ActorException' and 
-- forwarded to the monitoring actor. If the monitored
-- actor terminates, an 'ActorException' is raised in
-- the monitoring Actor
monitor :: Address a b -> ActorM c d ()
monitor addr = do
    me <- liftIO myThreadId
    let mv = aMVar addr
    liftIO $ modifyMVar_ mv (\set -> return $ insert me set)

-- | Like `monitor`, but bi-directional
link :: Address a b -> ActorM c d ()
link addr = do
    monitor addr
    mv <- asks cMVar
    let ti = aTId addr
    liftIO $ modifyMVar_ mv (\set -> return $ insert ti set)
