-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2011 Alex Constandache
-- License     :  BSD3
-- Maintainer  :  alexander.the.average@gmail.com
-- Stability   :  alpha
-- Portability :  portable
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
module Control.Concurrent.Actor (
   -- * Types
    Address
   ,ActorM
   ,Actor
   -- * Actor actions
   ,send
   ,(◁)
   ,(▷)
   ,receive
   ,receiveWithTimeout
   ,spawn
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Monad.Reader
import System.Timeout


data Dialog a b = Dia 
  { message :: a 
  , address :: Address b a
  }

diaToPair :: Dialog a b -> (a, Address b a)
diaToPair d = (message d, address d)

-- | The address of an actor that accepts messages of
-- type /a/ and sends messages of type /b/ 
newtype Address a b = Addr { unAddr :: Dialog a b -> IO () }

newtype Mailbox a b = Mbox { unMbox :: Chan (Dialog a b) }

-- | The actor monad, just a reader monad on top of 'IO'.
-- It carries information about an actor's mailbox, which is
-- hidden from the library's users.
type ActorM a b = ReaderT (Mailbox a b) IO 

-- | The type of an actor accepting messages of type /a/ and
-- returning messages of type /b/. It is just a monadic action
-- in the 'ActorM' monad, returning ()
type Actor a b = ActorM a b ()

-- | Receive a message inside the 'ActorM' monad. Blocks until
-- a message arrives if the mailbox is empty
receive :: ActorM a b (a, Address b a)
receive = do
    chan <- asks unMbox 
    let pair = liftM diaToPair $ readChan chan
    liftIO pair

-- | Same as receive, but times out after a specified 
-- amount of time and returns 'Nothing'
receiveWithTimeout :: Int -> ActorM a b (Maybe (a, Address b a))
receiveWithTimeout n = do 
   chan <- asks unMbox 
   let mpair = timeout n . liftM diaToPair $ readChan chan
   liftIO mpair

-- | Sends a message from inside the 'ActorM' monad
send :: Address a b -> a -> ActorM b a ()
send addr msg = do
    chan <- asks unMbox 
    let self = Addr $ writeChan chan
    liftIO $ unAddr addr (Dia msg self)

-- | Infix form of 'send'
(◁) :: Address a b -> a -> ActorM b a ()
(◁) = send
    
-- | Infix form of 'send' with the arguments flipped
(▷) :: a -> Address a b -> ActorM b a ()
(▷) = flip send

-- | Spawns a new actor
spawn :: Actor a b -> IO (Address a b)
spawn act = do
    chan <- liftIO newChan
    forkIO $ runReaderT act (Mbox chan)
    return $ Addr (writeChan chan)
    
