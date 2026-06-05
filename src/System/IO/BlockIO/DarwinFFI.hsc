{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE NamedFieldPuns   #-}

{-# OPTIONS_GHC -fobject-code #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- | macOS Darwin backend for the platform FFI layer.
-- Exports the same names as URingFFI so that URing.hs can import
-- whichever module is appropriate via CPP.
module System.IO.BlockIO.DarwinFFI where

import Foreign
import Foreign.C
import Prelude hiding (head, tail)
import System.Posix.Types

#include "darwin_io.h"
#include <errno.h>

-- ---------------------------------------------------------------------------
-- URing  (stores a darwin_ring* in malloc'd pointer-sized storage)
-- ---------------------------------------------------------------------------

data URing = URing

instance Storable URing where
  sizeOf    _ = sizeOf    (nullPtr :: Ptr ())
  alignment _ = alignment (nullPtr :: Ptr ())
  peek      _ = return URing
  poke    _ _ = return ()

-- Internal helpers to read/write the embedded darwin_ring* pointer.
getRingPtr :: Ptr URing -> IO (Ptr ())
getRingPtr p = peek (castPtr p :: Ptr (Ptr ()))

setRingPtr :: Ptr URing -> Ptr () -> IO ()
setRingPtr p rp = poke (castPtr p :: Ptr (Ptr ())) rp

-- ---------------------------------------------------------------------------
-- URingParams  (pure Haskell struct; not a C struct)
-- ---------------------------------------------------------------------------

data URingParams = URingParams
    { sq_entries :: !CUInt
    , cq_entries :: !CUInt
    , flags      :: !CUInt
    , features   :: !CUInt
    } deriving stock (Show, Eq)

instance Storable URingParams where
  sizeOf    _ = 4 * sizeOf (0 :: CUInt)
  alignment _ = alignment  (0 :: CUInt)
  peek p = URingParams
              <$> peekByteOff p  0
              <*> peekByteOff p  4
              <*> peekByteOff p  8
              <*> peekByteOff p 12
  poke p URingParams{sq_entries, cq_entries, flags, features} = do
      pokeByteOff p  0 sq_entries
      pokeByteOff p  4 cq_entries
      pokeByteOff p  8 flags
      pokeByteOff p 12 features

-- Not used on Darwin; present so URing.hs compiles unchanged.
iORING_SETUP_CQSIZE :: CUInt
iORING_SETUP_CQSIZE = 0

-- ---------------------------------------------------------------------------
-- URingSQE  (opaque; only ever used as Ptr URingSQE)
-- ---------------------------------------------------------------------------

data URingSQE

-- ---------------------------------------------------------------------------
-- URingCQE  (mirrors darwin_cqe layout)
-- ---------------------------------------------------------------------------

data URingCQE = URingCQE
    { cqe_data :: !CULong
    , cqe_res  :: !CInt
    } deriving stock Show

instance Storable URingCQE where
  sizeOf    _ = #{size      darwin_cqe}
  alignment _ = #{alignment darwin_cqe}
  peek p = URingCQE
              <$> #{peek darwin_cqe, user_data} p
              <*> #{peek darwin_cqe, res}       p
  poke _ _ = return ()

-- ---------------------------------------------------------------------------
-- Low-level C imports
-- ---------------------------------------------------------------------------

foreign import ccall unsafe "darwin_io.h darwin_ring_create"
  c_darwin_ring_create :: CUInt -> CUInt -> IO (Ptr ())

foreign import ccall unsafe "darwin_io.h darwin_ring_destroy"
  c_darwin_ring_destroy :: Ptr () -> IO ()

foreign import ccall unsafe "darwin_io.h darwin_get_sqe"
  c_darwin_get_sqe :: Ptr () -> IO (Ptr URingSQE)

foreign import ccall unsafe "darwin_io.h darwin_sqe_set_data"
  c_darwin_sqe_set_data :: Ptr URingSQE -> CULong -> IO ()

foreign import ccall unsafe "darwin_io.h darwin_prep_read"
  c_darwin_prep_read :: Ptr URingSQE -> CInt -> Ptr Word8 -> CUInt -> CULong -> IO ()

foreign import ccall unsafe "darwin_io.h darwin_prep_write"
  c_darwin_prep_write :: Ptr URingSQE -> CInt -> Ptr Word8 -> CUInt -> CULong -> IO ()

foreign import ccall unsafe "darwin_io.h darwin_prep_nop"
  c_darwin_prep_nop :: Ptr URingSQE -> IO ()

foreign import ccall unsafe "darwin_io.h darwin_submit"
  c_darwin_submit :: Ptr () -> IO CInt

-- interruptible so GHC can deliver async exceptions while blocked in kevent
foreign import ccall interruptible "darwin_io.h darwin_wait_cqe"
  c_darwin_wait_cqe :: Ptr () -> Ptr (Ptr URingCQE) -> IO CInt

foreign import ccall unsafe "darwin_io.h darwin_peek_cqe"
  c_darwin_peek_cqe :: Ptr () -> Ptr (Ptr URingCQE) -> IO CInt

foreign import ccall unsafe "darwin_io.h darwin_cqe_seen"
  c_darwin_cqe_seen :: Ptr () -> Ptr URingCQE -> IO ()

-- ---------------------------------------------------------------------------
-- Public interface  (same names as URingFFI)
-- ---------------------------------------------------------------------------

io_uring_queue_init_params :: CUInt -> Ptr URing -> Ptr URingParams -> IO CInt
io_uring_queue_init_params sq_size ringptr paramsptr = do
    params <- peek paramsptr
    let cq_sz = cq_entries params
    ring <- c_darwin_ring_create sq_size cq_sz
    if ring == nullPtr
      then return (negate #{const ENOMEM})
      else do
        setRingPtr ringptr ring
        poke paramsptr params { sq_entries = sq_size, cq_entries = cq_sz }
        return 0

io_uring_queue_exit :: Ptr URing -> IO ()
io_uring_queue_exit ringptr = do
    ring <- getRingPtr ringptr
    c_darwin_ring_destroy ring

io_uring_get_sqe :: Ptr URing -> IO (Ptr URingSQE)
io_uring_get_sqe ringptr = do
    ring <- getRingPtr ringptr
    c_darwin_get_sqe ring

io_uring_sqe_set_data :: Ptr URingSQE -> CULong -> IO ()
io_uring_sqe_set_data = c_darwin_sqe_set_data

io_uring_prep_read :: Ptr URingSQE -> Fd -> Ptr Word8 -> CUInt -> CULong -> IO ()
io_uring_prep_read sqeptr (Fd fd) buf len off =
    c_darwin_prep_read sqeptr fd buf len off

io_uring_prep_write :: Ptr URingSQE -> Fd -> Ptr Word8 -> CUInt -> CULong -> IO ()
io_uring_prep_write sqeptr (Fd fd) buf len off =
    c_darwin_prep_write sqeptr fd buf len off

io_uring_prep_nop :: Ptr URingSQE -> IO ()
io_uring_prep_nop = c_darwin_prep_nop

io_uring_submit :: Ptr URing -> IO CInt
io_uring_submit ringptr = do
    ring <- getRingPtr ringptr
    c_darwin_submit ring

io_uring_wait_cqe :: Ptr URing -> Ptr (Ptr URingCQE) -> IO CInt
io_uring_wait_cqe ringptr cqeptrptr = do
    ring <- getRingPtr ringptr
    c_darwin_wait_cqe ring cqeptrptr

io_uring_peek_cqe :: Ptr URing -> Ptr (Ptr URingCQE) -> IO CInt
io_uring_peek_cqe ringptr cqeptrptr = do
    ring <- getRingPtr ringptr
    c_darwin_peek_cqe ring cqeptrptr

io_uring_cqe_seen :: Ptr URing -> Ptr URingCQE -> IO ()
io_uring_cqe_seen ringptr cqeptr = do
    ring <- getRingPtr ringptr
    c_darwin_cqe_seen ring cqeptr

-- Not applicable on Darwin; io_uring_set_iowait is a Linux-only feature.
io_uring_set_iowait :: Ptr URing -> CBool -> IO CInt
io_uring_set_iowait _ _ = pure (negate #{const EOPNOTSUPP})
