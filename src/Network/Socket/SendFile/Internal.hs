{-# LANGUAGE CPP, RecordWildCards #-}
module Network.Socket.SendFile.Internal (
    sendFile,
    sendFileIterWith,
    sendFile',
    sendFileIterWith',
    unsafeSendFile,
    unsafeSendFileIterWith,
    unsafeSendFile',
    unsafeSendFileIterWith',
    sendFileMode,
    ) where
#if defined(PORTABLE_SENDFILE)
import Data.ByteString.Char8 (hGet, hPut, length, ByteString)
import qualified Data.ByteString.Char8 as C
import Network.Socket.ByteString (send, sendAll)
import Network.Socket (Socket(..), fdSocket)
import Network.Socket.SendFile.Iter (runIter)
import Prelude hiding (length)
import System.IO (Handle, IOMode(..), SeekMode(..), hFileSize, hIsEOF, hSeek, withBinaryFile)
import System.Posix.Types (Fd(..))
#else
import Network.Socket (Socket(..), fdSocket)
import System.IO (Handle, IOMode(..), hFileSize, withBinaryFile)
import System.Posix.Types (Fd(..))
#endif

import Network.Socket.SendFile.Iter (Iter(..))


#ifdef __GLASGOW_HASKELL__
#if __GLASGOW_HASKELL__ >= 611
import GHC.IO.Handle.Internals (withHandle_)
import GHC.IO.Handle.Types (Handle__(..))
import qualified GHC.IO.FD as FD
-- import qualified GHC.IO.Handle.FD as FD
import GHC.IO.Exception
import Data.Typeable (cast)
import System.IO (hFlush)
import System.IO.Error
#else
import GHC.IOBase
import GHC.Handle hiding (fdToHandle)
import qualified GHC.Handle
#endif
#endif

#if defined(WIN32_SENDFILE)
import Network.Socket.SendFile.Win32 (_sendFile, sendFileIter)

sendFileMode :: String
sendFileMode = "WIN32_SENDFILE"
#endif

#if defined(LINUX_SENDFILE)
import Network.Socket.SendFile.Linux (_sendFile, sendFileIter)

sendFileMode :: String
sendFileMode = "LINUX_SENDFILE"
#endif

#if defined(FREEBSD_SENDFILE)
import Network.Socket.SendFile.FreeBSD (_sendFile, sendFileIter)

sendFileMode :: String
sendFileMode = "FREEBSD_SENDFILE"
#endif

#if defined(DARWIN_SENDFILE)
import Network.Socket.SendFile.Darwin (_sendFile, sendFileIter)

sendFileMode :: String
sendFileMode = "DARWIN_SENDFILE"
#endif

#if defined(PORTABLE_SENDFILE)
sendFileMode :: String
sendFileMode = "PORTABLE_SENDFILE"

sendFileIterWith'' :: (IO Iter -> IO a) -> Socket -> Handle -> Integer -> Integer -> Integer -> IO a
sendFileIterWith'' stepper =
    wrapSendFile' $ \outs inp blockSize off count ->
        do hSeek inp AbsoluteSeek off
           stepper (sendFileIterS outs inp blockSize {- off -} count Nothing)

sendFile'' :: Socket -> Handle -> Integer -> Integer -> IO ()
sendFile'' outs inh off count =
    do _ <- sendFileIterWith'' runIter outs inh count off count
       return ()

unsafeSendFileIterWith'' :: (IO Iter -> IO a) -> Handle -> Handle -> Integer -> Integer -> Integer -> IO a
unsafeSendFileIterWith'' stepper =
    wrapSendFile' $ \outp inp blockSize off count ->
        do hSeek inp AbsoluteSeek off
           a <- stepper (unsafeSendFileIter outp inp blockSize count Nothing)
           hFlush outp
           return a

unsafeSendFile'' :: Handle -> Handle -> Integer -> Integer -> IO ()
unsafeSendFile'' outh inh off count =
    do _ <- unsafeSendFileIterWith'' runIter outh inh count off count
       return ()

sendFileIterS :: Socket  -- ^ output network socket
             -> Handle  -- ^ input handle
             -> Integer -- ^ maximum number of bytes to send at once
             -> Integer -- ^ total number of bytes to send
             -> Maybe ByteString
             -> IO Iter
sendFileIterS _socket _inh _blockSize {- _off -} 0        _    = return (Done 0)
sendFileIterS socket   inh  blockSize {- off -} remaining mBuf =
    do buf <- nextBlock
       nsent <- send socket buf
       let leftOver =
               if nsent < (C.length buf)
                  then Just (C.drop nsent buf)
                  else Nothing
       let cont = sendFileIterS socket inh blockSize {- (off + (fromIntegral nsent)) -} (remaining `safeMinus` (fromIntegral nsent)) leftOver
       if nsent < (length buf)
          then return (WouldBlock (fromIntegral nsent) (Fd $ fdSocket socket) cont)
          else return (Sent       (fromIntegral nsent)                        cont)
    where
   nextBlock =
          case mBuf of
            (Just b) -> return b
            Nothing ->
                do eof <- hIsEOF inh
                   if eof
                    then ioError (mkIOError eofErrorType ("Reached EOF but was hoping to read " ++ show remaining ++ " more byte(s).") (Just inh) Nothing)
                    else do let bytes = min 32768 (min blockSize remaining)
                            hGet inh (fromIntegral bytes) -- we could check that we got fewer bytes than requested here, but we will send what we got and catch the EOF next time around

safeMinus :: (Ord a, Num a) => a -> a -> a
safeMinus x y
    | y > x = error $ "y > x " ++ show (y,x)
    | otherwise = x - y


unsafeSendFileIter :: Handle  -- ^ output handle
                   -> Handle  -- ^ input handle
                   -> Integer -- ^ maximum number of bytes to send at once
--                   -> Integer -- ^ offset into file
                   -> Integer -- ^ total number of bytes to send
                   -> Maybe ByteString
                   -> IO Iter
unsafeSendFileIter outh inh blockSize 0         mBuf = return (Done 0)
unsafeSendFileIter outh inh blockSize remaining mBuf =
    do buf <- nextBlock
       hPut outh buf -- eventually this should use a non-blocking version of hPut
       let nsent = length buf
{-
           leftOver =
               if nsent < (C.length buf)
                  then Just (C.drop nsent buf)
                  else Nothing
-}
           cont = unsafeSendFileIter outh inh blockSize {- (off + (fromIntegral nsent)) -} (remaining - (fromIntegral nsent)) Nothing
       if nsent < (length buf)
          then do error "unsafeSendFileIter: internal error" -- return (WouldBlock (fromIntegral nsent) (Fd $ fdSocket socket) cont)
          else return (Sent (fromIntegral nsent) cont)
    where
      nextBlock =
          case mBuf of
            (Just b) -> return b
            Nothing ->
                do eof <- hIsEOF inh
                   if eof
                    then ioError (mkIOError eofErrorType ("Reached EOF but was hoping to read " ++ show remaining ++ " more byte(s).") (Just inh) Nothing)
                    else do let bytes = min 32768 (min blockSize remaining)
                            hGet inh (fromIntegral bytes) -- we could check that we got fewer bytes than requested here, but we will send what we got and catch the EOF next time around

#else
sendFile'' :: Socket -> Handle -> Integer -> Integer -> IO ()
sendFile'' outs inh off count =
    do let out_fd = Fd (fdSocket outs)
       withFd inh $ \in_fd ->
         wrapSendFile' (\out_fd_ in_fd_ _blockSize_ off_ count_ -> _sendFile out_fd_ in_fd_ off_ count_)
                       out_fd in_fd count off count

sendFileIterWith'' :: (IO Iter -> IO a) -> Socket -> Handle -> Integer -> Integer -> Integer -> IO a
sendFileIterWith'' stepper outs inp blockSize off count =
    do let out_fd = Fd (fdSocket outs)
       withFd inp $ \in_fd ->
         stepper $ wrapSendFile' sendFileIter out_fd in_fd blockSize off count


unsafeSendFile'' :: Handle -> Handle -> Integer -> Integer -> IO ()
unsafeSendFile'' outp inp off count =
    do hFlush outp
       withFd outp $ \out_fd ->
         withFd inp $ \in_fd ->
          wrapSendFile' (\out_fd_ in_fd_ _blockSize_ off_ count_ -> _sendFile out_fd_ in_fd_ off_ count_)
                        out_fd in_fd count off count
--            wrapSendFile' _sendFile out_fd in_fd off count

unsafeSendFileIterWith'' :: (IO Iter -> IO a) -> Handle -> Handle -> Integer -> Integer -> Integer -> IO a
unsafeSendFileIterWith'' stepper outp inp blockSize off count =
    do hFlush outp
       withFd outp $ \out_fd ->
         withFd inp $ \in_fd ->
             stepper $ wrapSendFile' sendFileIter out_fd in_fd blockSize off count

-- The Fd should not be used after the action returns because the
-- Handler may be garbage collected and than will cause the finalizer
-- to close the fd.
withFd :: Handle -> (Fd -> IO a) -> IO a
#ifdef __GLASGOW_HASKELL__
#if __GLASGOW_HASKELL__ >= 611
withFd h f = withHandle_ "withFd" h $ \ Handle__{..} -> do
  case cast haDevice of
    Nothing -> ioError (ioeSetErrorString (mkIOError IllegalOperation
                                           "withFd" (Just h) Nothing)
                        "handle is not a file descriptor")
    Just fd -> f (Fd (fromIntegral (FD.fdFD fd)))
#else
withFd h f =
    withHandle_ "withFd" h $ \ h_ ->
      f (Fd (fromIntegral (haFD h_)))
#endif
#endif


#endif

sendFile :: Socket -> FilePath -> IO ()
sendFile outs infp =
    withBinaryFile infp ReadMode $ \inp -> do
      count <- hFileSize inp
      sendFile'' outs inp 0 count

sendFileIterWith :: (IO Iter -> IO a) -> Socket -> FilePath -> Integer -> IO a
sendFileIterWith stepper outs infp blockSize =
    withBinaryFile infp ReadMode $ \inp -> do
      count <- hFileSize inp
      sendFileIterWith'' stepper outs inp blockSize 0 count

sendFile' :: Socket -> FilePath -> Integer -> Integer -> IO ()
sendFile' outs infp offset count =
    withBinaryFile infp ReadMode $ \inp ->
        sendFile'' outs inp offset count

sendFileIterWith' :: (IO Iter -> IO a) -> Socket -> FilePath -> Integer -> Integer -> Integer -> IO a
sendFileIterWith' stepper outs infp blockSize offset count =
    withBinaryFile infp ReadMode $ \inp ->
        sendFileIterWith'' stepper outs inp blockSize offset count

unsafeSendFile :: Handle -> FilePath -> IO ()
unsafeSendFile outp infp =
    withBinaryFile infp ReadMode $ \inp -> do
      count <- hFileSize inp
      unsafeSendFile'' outp inp 0 count

unsafeSendFileIterWith :: (IO Iter -> IO a) -> Handle -> FilePath -> Integer -> IO a
unsafeSendFileIterWith stepper outp infp blockSize =
    withBinaryFile infp ReadMode $ \inp -> do
      count <- hFileSize inp
      unsafeSendFileIterWith'' stepper outp inp blockSize 0 count


unsafeSendFile'
    :: Handle    -- ^ The output handle
    -> FilePath  -- ^ The input filepath
    -> Integer    -- ^ The offset to start at
    -> Integer -- ^ The number of bytes to send
    -> IO ()
unsafeSendFile' outp infp offset count =
    withBinaryFile infp ReadMode $ \inp -> do
      unsafeSendFile'' outp inp offset count

unsafeSendFileIterWith'
    :: (IO Iter -> IO a)
    -> Handle    -- ^ The output handle
    -> FilePath  -- ^ The input filepath
    -> Integer   -- ^ maximum block size
    -> Integer   -- ^ The offset to start at
    -> Integer   -- ^ The number of bytes to send
    -> IO a
unsafeSendFileIterWith' stepper outp infp blockSize offset count =
    withBinaryFile infp ReadMode $ \inp -> do
      unsafeSendFileIterWith'' stepper outp inp blockSize offset count

-- | wraps sendFile' to check arguments
wrapSendFile' :: Integral i => (a -> b -> i -> i -> i -> IO c) -> a -> b -> Integer -> Integer -> Integer -> IO c
wrapSendFile' fun outp inp blockSize off count
--    | count     == 0 = return () -- Send nothing -- why do the work? Also, Windows and FreeBSD treat '0' as 'send the whole file'.
    | count     <  0 = error "SendFile - count must be a positive integer"
    | (count /= 0) && (blockSize <= 0) = error "SendFile - blockSize must be a positive integer greater than 1"
    | off       <  0 = error "SendFile - offset must be a positive integer"
    | otherwise      = fun outp inp (fromIntegral blockSize) (fromIntegral off) (fromIntegral count)

