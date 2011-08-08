{-# LANGUAGE Rank2Types #-}
module Control.Concurrent.Actor (
    Actor
   ,Address
   ,ActorM
   ,send
   ,receive
   ,receiveWithTimeout
   ,spawn
   ,(▷)
   ,(◁)
  ) where

import Control.Concurrent (ThreadId, forkIO)
import Control.Monad (void, liftM)
import Control.Concurrent.Chan
import Control.Monad.Reader
import System.Timeout


data Dialog a b = Dia 
  { message :: a 
  , address :: Address b a
  }

diaToPair :: Dialog a b -> (a, Address b a)
diaToPair d = (message d, address d)

newtype Address a b = Addr { unAddr :: Dialog a b -> IO () }

newtype Mailbox a b = Mbox { unMbox :: Chan (Dialog a b) }

type ActorM a b = ReaderT (Mailbox a b) IO 

type Actor a b = ActorM a b ()

receive :: ActorM a b (a, Address b a)
receive = do
    chan <- asks unMbox 
    let pair = liftM diaToPair $ readChan chan
    liftIO pair

receiveWithTimeout :: Int -> ActorM a b (Maybe (a, Address b a))
receiveWithTimeout n = do 
   chan <- asks unMbox 
   let mpair = timeout n . liftM diaToPair $ readChan chan
   liftIO mpair

send :: Address a b -> a -> ActorM b a ()
send addr msg = do
    chan <- asks unMbox 
    let self = Addr $ writeChan chan
    liftIO $ unAddr addr (Dia msg self)
    

(▷) :: a -> Address a b -> ActorM b a ()
(▷) = flip send

(◁) :: Address a b -> a -> ActorM b a ()
(◁) = send

spawn :: Actor a b -> IO (Address a b)
spawn act = do
    chan <- liftIO newChan
    forkIO $ runReaderT act (Mbox chan)
    return $ Addr (writeChan chan)
    
