module Control.Concurrent.Actor (
    Actor(..)
   ,ActorRef
   ,ActorM
   ,send
   ,self
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

newtype ActorRef a = ActR { mbox :: Chan a }

newActorRef :: IO (ActorRef a)
newActorRef = liftM ActR newChan

type ActorM a = ReaderT (ActorRef a) IO

type Actor a = ActorM a ()

send :: ActorRef a -> a -> IO ()
send act x = writeChan (mbox act) x

receive :: ActorM a a
receive = asks mbox >>= (liftIO . readChan)

receiveWithTimeout :: Int -> ActorM a (Maybe a)
receiveWithTimeout n = asks mbox >>= (liftIO . timeout n . readChan)

self :: ActorM a (ActorRef a)
self = ask

(▷) :: a -> ActorRef a -> IO ()
(▷) = flip send

(◁) :: ActorRef a -> a -> IO ()
(◁) = send

spawn :: Actor a -> IO (ActorRef a)
spawn act = do
    ref <- newActorRef :: IO (ActorRef a)
    forkIO $ runReaderT act ref
    return ref
    
