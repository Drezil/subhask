{-# LANGUAGE ForeignFunctionInterface #-}

-- | Efficient vectors and linear algebra operations.
-- FIXME:
-- shouldn't expose the constructors
--
-- FIXME:
-- "UVector" is implemented in terms of "Data.Vector.Unboxed.Vector";
-- we can probably make things a bit faster with our own implementation.
module SubHask.Algebra.Vector
    ( SVector (..)
    , UVector (..)
    , Unbox

    -- * FFI
    , distance_l2_m128
    , distance_l2_m128_SVector_Dynamic
    , distance_l2_m128_UVector_Dynamic

    , distanceUB_l2_m128
    , distanceUB_l2_m128_SVector_Dynamic
    , distanceUB_l2_m128_UVector_Dynamic

    -- * Debug
    , safeNewByteArray
    )
    where

import qualified Prelude as P

import Control.Monad.Primitive
import Control.Monad
import Data.Primitive hiding (sizeOf)
import Debug.Trace
import qualified Data.Primitive as Prim
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Marshal.Utils
import Test.QuickCheck.Gen (frequency)

import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM

import qualified Prelude as P
import SubHask.Algebra
import SubHask.Category
import SubHask.Internal.Prelude
import SubHask.Compatibility.Base

import Data.Csv (FromRecord,FromField,parseRecord)

import System.IO.Unsafe
import Unsafe.Coerce

--------------------------------------------------------------------------------

foreign import ccall unsafe "distance_l2_m128" distance_l2_m128
    :: Ptr Float -> Ptr Float -> Int -> IO Float

foreign import ccall unsafe "distanceUB_l2_m128" distanceUB_l2_m128
    :: Ptr Float -> Ptr Float -> Int -> Float -> IO Float

{-# INLINE sizeOfFloat #-}
sizeOfFloat :: Int
sizeOfFloat = sizeOf (undefined::Float)

{-# INLINE distance_l2_m128_UVector_Dynamic #-}
distance_l2_m128_UVector_Dynamic :: UVector (s::Symbol) Float -> UVector (s::Symbol) Float -> Float
distance_l2_m128_UVector_Dynamic (UVector_Dynamic arr1 off1 n) (UVector_Dynamic arr2 off2 _)
    = unsafeInlineIO $ distance_l2_m128 p1 p2 n
    where
        p1 = plusPtr (unsafeCoerce $ byteArrayContents arr1) (off1*sizeOfFloat)
        p2 = plusPtr (unsafeCoerce $ byteArrayContents arr2) (off2*sizeOfFloat)

{-# INLINE distanceUB_l2_m128_UVector_Dynamic #-}
distanceUB_l2_m128_UVector_Dynamic :: UVector (s::Symbol) Float -> UVector (s::Symbol) Float -> Float -> Float
distanceUB_l2_m128_UVector_Dynamic (UVector_Dynamic arr1 off1 n) (UVector_Dynamic arr2 off2 _) ub
    = unsafeInlineIO $ distanceUB_l2_m128 p1 p2 n ub
    where
        p1 = plusPtr (unsafeCoerce $ byteArrayContents arr1) (off1*sizeOfFloat)
        p2 = plusPtr (unsafeCoerce $ byteArrayContents arr2) (off2*sizeOfFloat)

distance_l2_m128_SVector_Dynamic :: SVector (s::Symbol) Float -> SVector (s::Symbol) Float -> Float
distance_l2_m128_SVector_Dynamic (SVector_Dynamic fp1 off1 n) (SVector_Dynamic fp2 off2 _)
    = unsafeInlineIO $
        withForeignPtr fp1 $ \p1 ->
        withForeignPtr fp2 $ \p2 ->
            distance_l2_m128 (plusPtr p1 $ off1*sizeOfFloat) (plusPtr p2 $ off2*sizeOfFloat) n

distanceUB_l2_m128_SVector_Dynamic :: SVector (s::Symbol) Float -> SVector (s::Symbol) Float -> Float -> Float
distanceUB_l2_m128_SVector_Dynamic (SVector_Dynamic fp1 off1 n) (SVector_Dynamic fp2 off2 _) ub
    = unsafeInlineIO $
        withForeignPtr fp1 $ \p1 ->
        withForeignPtr fp2 $ \p2 ->
            distanceUB_l2_m128 (plusPtr p1 $ off1*sizeOfFloat) (plusPtr p2 $ off2*sizeOfFloat) n ub

--------------------------------------------------------------------------------

type Unbox = VU.Unbox

--------------------------------------------------------------------------------

-- | The type of dynamic or statically sized vectors implemented using the FFI.
data family UVector (n::k) r

type instance Scalar (UVector n r) = Scalar r
type instance Logic (UVector n r) = Logic r
type instance UVector n r >< a = UVector n (r><a)

type instance Index (UVector n r) = Int
type instance Elem (UVector n r) = Scalar r
type instance SetElem (UVector n r) b = UVector n b

--------------------------------------------------------------------------------

data instance UVector (n::Symbol) r = UVector_Dynamic
    {-#UNPACK#-}!ByteArray
    {-#UNPACK#-}!Int -- ^ offset
    {-#UNPACK#-}!Int -- ^ length

instance (Show r, Monoid r, Prim r) => Show (UVector (n::Symbol) r) where
    show (UVector_Dynamic arr off n) = if isZero n
        then "zero"
        else show $ go (n-1) []
        where
            go (-1) xs = xs
            go i    xs = go (i-1) (x:xs)
                where
                    x = indexByteArray arr (off+i) :: r

instance (Arbitrary r, Prim r, FreeModule r, IsScalar r) => Arbitrary (UVector (n::Symbol) r) where
    arbitrary = frequency
        [ (1,return zero)
        , (9,fmap unsafeToModule $ replicateM 27 arbitrary)
        ]

instance (NFData r, Prim r) => NFData (UVector (n::Symbol) r) where
    rnf (UVector_Dynamic arr off n) = seq arr ()

instance (FromField r, Prim r, IsScalar r, FreeModule r) => FromRecord (UVector (n::Symbol) r) where
    parseRecord r = do
        rs :: [r] <- parseRecord r
        return $ unsafeToModule rs

---------------------------------------
-- mutable

newtype instance Mutable m (UVector (n::Symbol) r)
    = Mutable_UVector (PrimRef m (UVector (n::Symbol) r))

instance Prim r => IsMutable (UVector (n::Symbol) r) where
    freeze mv = copy mv >>= unsafeFreeze
    thaw v = unsafeThaw v >>= copy

    unsafeFreeze (Mutable_UVector ref) = readPrimRef ref
    unsafeThaw v = do
        ref <- newPrimRef v
        return $ Mutable_UVector ref

    copy (Mutable_UVector ref) = do
        (UVector_Dynamic arr1 off1 n) <- readPrimRef ref
        let b = (extendDimensions n)*Prim.sizeOf (undefined::r)
        if n==0
            then do
                ref <- newPrimRef $ UVector_Dynamic arr1 off1 n
                return $ Mutable_UVector ref
            else unsafePrimToPrim $ do
                marr2 <- safeNewByteArray b 16
                copyByteArray marr2 0 arr1 off1 b
                arr2 <- unsafeFreezeByteArray marr2
                ref2 <- newPrimRef (UVector_Dynamic arr2 0 n)
                return $ Mutable_UVector ref2

    write (Mutable_UVector ref) (UVector_Dynamic arr2 off2 n2) = do
        (UVector_Dynamic arr1 off1 n1) <- readPrimRef ref
        unsafePrimToPrim $ if
            -- both ptrs null: do nothing
            | n1==0 && n2==0 -> return ()

            -- only arr1 null: allocate memory then copy arr2 over
            | n1==0 -> do
                marr1' <- safeNewByteArray b 16
                copyByteArray marr1' 0 arr2 off2 b
                arr1' <- unsafeFreezeByteArray marr1'
                unsafePrimToPrim $ writePrimRef ref (UVector_Dynamic arr1' 0 n2)

            -- only arr2 null: make arr1 null
            | n2==0 -> do
                writePrimRef ref (UVector_Dynamic arr2 0 n1)

            -- both ptrs valid: perform a normal copy
            | otherwise -> do
                marr1 <- unsafeThawByteArray arr1
                copyByteArray marr1 off1 arr2 off2 b

        where b = (extendDimensions n2)*Prim.sizeOf (undefined::r)

----------------------------------------
-- algebra

extendDimensions :: Int -> Int
extendDimensions i = i+i`rem`4

safeNewByteArray :: PrimMonad m => Int -> Int -> m (MutableByteArray (PrimState m))
safeNewByteArray b 16 = do
    let n=extendDimensions $ b`rem`4
    marr <- newAlignedPinnedByteArray b 16
    writeByteArray marr (n-0) (0::Float)
    writeByteArray marr (n-1) (0::Float)
    writeByteArray marr (n-2) (0::Float)
    writeByteArray marr (n-3) (0::Float)
    return marr

{-# INLINE binopDynUV #-}
binopDynUV :: forall a b n m.
    ( Prim a
    , Monoid a
    ) => (a -> a -> a) -> UVector (n::Symbol) a -> UVector (n::Symbol) a -> UVector (n::Symbol) a
binopDynUV f v1@(UVector_Dynamic arr1 off1 n1) v2@(UVector_Dynamic arr2 off2 n2) = if
    | isZero n1 && isZero n2 -> v1
    | isZero n1 -> monopDynUV (f zero) v2
    | isZero n2 -> monopDynUV (\a -> f a zero) v1
    | otherwise -> unsafeInlineIO $ do
        let b = (extendDimensions n1)*Prim.sizeOf (undefined::a)
        marr3 <- safeNewByteArray b 16
        go marr3 (n1-1)
        arr3 <- unsafeFreezeByteArray marr3
        return $ UVector_Dynamic arr3 0 n1

    where
        go _ (-1) = return ()
        go marr3 i = do
            let v1 = indexByteArray arr1 (off1+i)
                v2 = indexByteArray arr2 (off2+i)
            writeByteArray marr3 i (f v1 v2)
            go marr3 (i-1)

{-# INLINE monopDynUV #-}
monopDynUV :: forall a b n m.
    ( Prim a
    ) => (a -> a) -> UVector (n::Symbol) a -> UVector (n::Symbol) a
monopDynUV f v@(UVector_Dynamic arr1 off1 n) = if n==0
    then v
    else unsafeInlineIO $ do
        let b = n*Prim.sizeOf (undefined::a)
        marr2 <- safeNewByteArray b 16
        go marr2 (n-1)
        arr2 <- unsafeFreezeByteArray marr2
        return $ UVector_Dynamic arr2 0 n

    where
        go _ (-1) = return ()
        go marr2 i = do
            let v1 = indexByteArray arr1 (off1+i)
            writeByteArray marr2 i (f v1)
            go marr2 (i-1)

{-
{-# INLINE binopDynUVM #-}
binopDynUVM :: forall a b n m.
    ( PrimBase m
    , Prim a
    , Prim b
    , Monoid a
    , Monoid b
    ) => (a -> b -> a) -> Mutable m (UVector (n::Symbol) a) -> UVector n b -> m ()
binopDynUVM f (Mutable_UVector ref) (UVector_Dynamic arr2 off2 n2) = do
    (UVector_Dynamic arr1 off1 n1) <- readPrimRef ref

    let runop arr1 arr2 n = unsafePrimToPrim $
            withForeignPtr arr1 $ \p1 ->
            withForeignPtr arr2 $ \p2 ->
                go (plusPtr p1 off1) (plusPtr p2 off2) (n-1)

    unsafePrimToPrim $ if
        -- both vectors are zero: do nothing
        | isNull arr1 && isNull arr2 -> return ()

        -- only left vector is zero: allocate space and overwrite old vector
        -- FIXME: this algorithm requires two passes over the left vector
        | isNull arr1 -> do
            arr1' <- zerofp n2
            unsafePrimToPrim $ writePrimRef ref (UVector_Dynamic arr1' 0 n2)
            runop arr1' arr2 n2

        -- only right vector is zero: use a temporary zero vector to run like normal
        -- FIXME: this algorithm requires an unneeded memory allocation and memory pass
        | isNull arr2 -> do
            arr2' <- zerofp n1
            runop arr1 arr2' n1

        -- both vectors nonzero: run like normal
        | otherwise -> runop arr1 arr2 n1

    where
        go _ _ (-1) = return ()
        go p1 p2 i = do
            v1 <- peekElemOff p1 i
            v2 <- peekElemOff p2 i
            pokeElemOff p1 i (f v1 v2)
            go p1 p2 (i-1)

{-# INLINE monopDynM #-}
monopDynM :: forall a b n m.
    ( PrimMonad m
    , Prim a
    ) => (a -> a) -> Mutable m (UVector (n::Symbol) a) -> m ()
monopDynM f (Mutable_UVector ref) = do
    (UVector_Dynamic arr1 off1 n) <- readPrimRef ref
    if isNull arr1
        then return ()
        else unsafePrimToPrim $
            withForeignPtr arr1 $ \p1 ->
                go (plusPtr p1 off1) (n-1)

    where
        go _ (-1) = return ()
        go p1 i = do
            v1 <- peekElemOff p1 i
            pokeElemOff p1 i (f v1)
            go p1 (i-1)

-------------------

-}
instance (Monoid r, Prim r) => Semigroup (UVector (n::Symbol) r) where
    {-# INLINE (+)  #-} ; (+)  = binopDynUV  (+)
--     {-# INLINE (+=) #-} ; (+=) = binopDynUVM (+)

instance (Monoid r, Cancellative r, Prim r) => Cancellative (UVector (n::Symbol) r) where
    {-# INLINE (-)  #-} ; (-)  = binopDynUV  (-)
--     {-# INLINE (-=) #-} ; (-=) = binopDynUVM (-)

instance (Monoid r, Prim r) => Monoid (UVector (n::Symbol) r) where
    {-# INLINE zero #-}
    zero = unsafeInlineIO $ do
        marr <- safeNewByteArray 0 16
        arr <- unsafeFreezeByteArray marr
        return $ UVector_Dynamic arr 0 0

instance (Group r, Prim r) => Group (UVector (n::Symbol) r) where
    {-# INLINE negate #-}
    negate v = monopDynUV negate v

instance (Monoid r, Abelian r, Prim r) => Abelian (UVector (n::Symbol) r)

instance (Module r, Prim r) => Module (UVector (n::Symbol) r) where
    {-# INLINE (.*)   #-} ;  (.*)  v r = monopDynUV  (.*r) v
--     {-# INLINE (.*=)  #-} ;  (.*=) v r = monopDynM (.*r) v

instance (FreeModule r, Prim r) => FreeModule (UVector (n::Symbol) r) where
    {-# INLINE (.*.)  #-} ;  (.*.)     = binopDynUV  (.*.)
--     {-# INLINE (.*.=) #-} ;  (.*.=)    = binopDynUVM (.*.)

instance (VectorSpace r, Prim r) => VectorSpace (UVector (n::Symbol) r) where
    {-# INLINE (./)   #-} ;  (./)  v r = monopDynUV  (./r) v
--     {-# INLINE (./=)  #-} ;  (./=) v r = monopDynM (./r) v

    {-# INLINE (./.)  #-} ;  (./.)     = binopDynUV  (./.)
--     {-# INLINE (./.=) #-} ;  (./.=)    = binopDynUVM (./.)

----------------------------------------
-- container

instance (Monoid r, ValidLogic r, Prim r, IsScalar r) => IxContainer (UVector (n::Symbol) r) where

    {-# INLINE (!) #-}
    (!) (UVector_Dynamic arr off n) i = indexByteArray arr (off+i)

    {-# INLINABLE toIxList #-}
    toIxList (UVector_Dynamic arr off n) = P.zip [0..] $ go (n-1) []
        where
            go (-1) xs = xs
            go i xs = go (i-1) (indexByteArray arr (off+i) : xs)

instance (FreeModule r, ValidLogic r, Prim r, IsScalar r) => FiniteModule (UVector (n::Symbol) r) where

    {-# INLINE dim #-}
    dim (UVector_Dynamic _ _ n) = n

    {-# INLINABLE unsafeToModule #-}
    unsafeToModule xs = unsafeInlineIO $ do
        marr <- safeNewByteArray (n*Prim.sizeOf (undefined::r)) 16
        go marr (P.reverse xs) (n-1)
        arr <- unsafeFreezeByteArray marr
        return $ UVector_Dynamic arr 0 n

        where
            n = length xs

            go marr []  (-1) = return ()
            go marr (x:xs) i = do
                writeByteArray marr i x
                go marr xs (i-1)

----------------------------------------
-- comparison

isConst :: (Prim r, Eq_ r, ValidLogic r) => UVector (n::Symbol) r -> r -> Logic r
isConst (UVector_Dynamic arr1 off1 n1) c = go (off1+n1-1)
    where
        go (-1) = true
        go i = indexByteArray arr1 i==c && go (i-1)

instance (Eq r, Monoid r, Prim r) => Eq_ (UVector (n::Symbol) r) where
    {-# INLINE (==) #-}
    v1@(UVector_Dynamic arr1 off1 n1)==v2@(UVector_Dynamic arr2 off2 n2) = if
        | isZero n1 && isZero n2 -> true
        | isZero n1 -> isConst v2 zero
        | isZero n2 -> isConst v1 zero
        | otherwise -> go (n1-1)
        where
            go (-1) = true
            go i = v1==v2 && go (i-1)
                where
                    v1 = indexByteArray arr1 (off1+i) :: r
                    v2 = indexByteArray arr2 (off2+i) :: r

{-


{-# INLINE innerp #-}
-- innerp :: UVector 200 Float -> UVector 200 Float -> Float
innerp v1 v2 = go 0 (n-1)

    where
        n = 200
--         n = nat2int (Proxy::Proxy n)

        go !tot !i =  if i<4
            then goEach tot i
            else
                go (tot+(v1!(i  ) * v2!(i  ))
                       +(v1!(i-1) * v2!(i-1))
                       +(v1!(i-2) * v2!(i-2))
                       +(v1!(i-3) * v2!(i-3))
                   ) (i-4)

        goEach !tot !i = if i<0
            then tot
            else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)
-}

----------------------------------------
-- distances

instance
    ( Prim r
    , ExpField r
    , Normed r
    , Ord_ r
    , Logic r~Bool
    , IsScalar r
    , VectorSpace r
    ) => Metric (UVector (n::Symbol) r)
        where

    {-# INLINE[2] distance #-}
    distance v1@(UVector_Dynamic arr1 off1 n1) v2@(UVector_Dynamic arr2 off2 n2)
      = {-# SCC distance_UVector #-} if
        | isZero n1 -> size v2
        | isZero n2 -> size v1
        | otherwise -> sqrt $ go 0 (n1-1)
        where
            go !tot !i =  if i<4
                then goEach tot i
                else go (tot+(v1!(i  ) - v2!(i  )) .*. (v1!(i  ) - v2!(i  ))
                            +(v1!(i-1) - v2!(i-1)) .*. (v1!(i-1) - v2!(i-1))
                            +(v1!(i-2) - v2!(i-2)) .*. (v1!(i-2) - v2!(i-2))
                            +(v1!(i-3) - v2!(i-3)) .*. (v1!(i-3) - v2!(i-3))
                        )
                        (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot + (v1!i-v2!i).*.(v1!i-v2!i)) (i-1)

    {-# INLINE[2] distanceUB #-}
    distanceUB v1@(UVector_Dynamic arr1 off1 n1) v2@(UVector_Dynamic arr2 off2 n2) ub
      = {-# SCC distanceUB_UVector #-} if
        | isZero n1 -> size v2
        | isZero n2 -> size v1
        | otherwise -> sqrt $ go 0 (n1-1)
        where
            ub2=ub*ub

            go !tot !i = if tot>ub2
                then tot
                else if i<4
                    then goEach tot i
                    else go (tot+(v1!(i  ) - v2!(i  )) .*. (v1!(i  ) - v2!(i  ))
                                +(v1!(i-1) - v2!(i-1)) .*. (v1!(i-1) - v2!(i-1))
                                +(v1!(i-2) - v2!(i-2)) .*. (v1!(i-2) - v2!(i-2))
                                +(v1!(i-3) - v2!(i-3)) .*. (v1!(i-3) - v2!(i-3))
                            )
                            (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot + (v1!i-v2!i).*.(v1!i-v2!i)) (i-1)


instance (VectorSpace r, Prim r, IsScalar r, ExpField r) => Normed (UVector (n::Symbol) r) where
    {-# INLINE size #-}
    size v@(UVector_Dynamic arr off n) = if isZero n
        then 0
        else sqrt $ go 0 (off+n-1)
        where
            go !tot !i =  if i<4
                then goEach tot i
                else go (tot+v!(i  ).*.v!(i  )
                            +v!(i-1).*.v!(i-1)
                            +v!(i-2).*.v!(i-2)
                            +v!(i-3).*.v!(i-3)
                        ) (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot+v!i*v!i) (i-1)

--------------------------------------------------------------------------------
-- helper functions for memory management

-- | does the foreign pointer equal null?
isNull :: ForeignPtr a -> Bool
isNull fp = unsafeInlineIO $ withForeignPtr fp $ \p -> (return $ p P.== nullPtr)

-- | allocates a ForeignPtr that is filled with n "zero"s
zerofp :: forall n r. (Storable r, Monoid r) => Int -> IO (ForeignPtr r)
zerofp n = do
    fp <- mallocForeignPtrBytes b
    withForeignPtr fp $ \p -> go p (n-1)
    return fp
    where
        b = n*sizeOf (undefined::r)

        go _ (-1) = return ()
        go p i = do
            pokeElemOff p i zero
            go p (i-1)

--------------------------------------------------------------------------------

-- | The type of dynamic or statically sized vectors implemented using the FFI.
data family SVector (n::k) r

type instance Scalar (SVector n r) = Scalar r
type instance Logic (SVector n r) = Logic r
type instance SVector n r >< a = SVector n (r><a)

type instance Index (SVector n r) = Int
type instance Elem (SVector n r) = Scalar r
type instance SetElem (SVector n r) b = SVector n b

--------------------------------------------------------------------------------

data instance SVector (n::Symbol) r = SVector_Dynamic
    {-#UNPACK#-}!(ForeignPtr r)
    {-#UNPACK#-}!Int -- ^ offset
    {-#UNPACK#-}!Int -- ^ length

instance (Show r, Monoid r, Storable r) => Show (SVector (n::Symbol) r) where
    show (SVector_Dynamic fp off n) = if isNull fp
        then "zero"
        else show $ unsafeInlineIO $ go (n-1) []
        where
            go (-1) xs = return $ xs
            go i    xs = withForeignPtr fp $ \p -> do
                x <- peekElemOff p (off+i)
                go (i-1) (x:xs)

instance (Arbitrary r, Storable r, FreeModule r, IsScalar r) => Arbitrary (SVector (n::Symbol) r) where
    arbitrary = frequency
        [ (1,return zero)
        , (9,fmap unsafeToModule $ replicateM 27 arbitrary)
        ]

instance (NFData r, Storable r) => NFData (SVector (n::Symbol) r) where
    rnf (SVector_Dynamic fp off n) = seq fp ()

instance (FromField r, Storable r, IsScalar r, FreeModule r) => FromRecord (SVector (n::Symbol) r) where
    parseRecord r = do
        rs :: [r] <- parseRecord r
        return $ unsafeToModule rs

---------------------------------------
-- mutable

newtype instance Mutable m (SVector (n::Symbol) r) = Mutable_SVector (PrimRef m (SVector (n::Symbol) r))

instance (Storable r) => IsMutable (SVector (n::Symbol) r) where
    freeze mv = copy mv >>= unsafeFreeze
    thaw v = unsafeThaw v >>= copy

    unsafeFreeze (Mutable_SVector ref) = readPrimRef ref
    unsafeThaw v = do
        ref <- newPrimRef v
        return $ Mutable_SVector ref

    copy (Mutable_SVector ref) = do
        (SVector_Dynamic fp1 off1 n) <- readPrimRef ref
        let b = n*sizeOf (undefined::r)
        fp2 <- if isNull fp1
            then return fp1
            else unsafePrimToPrim $ do
                fp2 <- mallocForeignPtrBytes b
                withForeignPtr fp1 $ \p1 -> withForeignPtr fp2 $ \p2 -> copyBytes p2 (plusPtr p1 off1) b
                return fp2
        ref2 <- newPrimRef (SVector_Dynamic fp2 0 n)
        return $ Mutable_SVector ref2

    write (Mutable_SVector ref) (SVector_Dynamic fp2 off2 n2) = do
        (SVector_Dynamic fp1 off1 n1) <- readPrimRef ref
        unsafePrimToPrim $ if
            -- both ptrs null: do nothing
            | isNull fp1 && isNull fp2 -> return ()

            -- only fp1 null: allocate memory then copy fp2 over
            | isNull fp1 && not isNull fp2 -> do
                fp1' <- mallocForeignPtrBytes b
                unsafePrimToPrim $ writePrimRef ref (SVector_Dynamic fp1' 0 n2)
                withForeignPtr fp1' $ \p1 -> withForeignPtr fp2 $ \p2 ->
                    copyBytes p1 p2 b

            -- only fp2 null: make fp1 null
            | not isNull fp1 && isNull fp2 -> unsafePrimToPrim $ writePrimRef ref (SVector_Dynamic fp2 0 n1)

            -- both ptrs valid: perform a normal copy
            | otherwise ->
                withForeignPtr fp1 $ \p1 ->
                withForeignPtr fp2 $ \p2 ->
                    copyBytes p1 p2 b
            where b = n2*sizeOf (undefined::r)

----------------------------------------
-- algebra

{-# INLINE binopDyn #-}
binopDyn :: forall a b n m.
    ( Storable a
    , Monoid a
    ) => (a -> a -> a) -> SVector (n::Symbol) a -> SVector (n::Symbol) a -> SVector (n::Symbol) a
binopDyn f v1@(SVector_Dynamic fp1 off1 n1) v2@(SVector_Dynamic fp2 off2 n2) = if
    | isNull fp1 && isNull fp2 -> v1
    | isNull fp1 -> monopDyn (f zero) v2
    | isNull fp2 -> monopDyn (\a -> f a zero) v1
    | otherwise -> unsafeInlineIO $ do
        let b = n1*sizeOf (undefined::a)
        fp3 <- mallocForeignPtrBytes b
        withForeignPtr fp1 $ \p1 ->
            withForeignPtr fp2 $ \p2 ->
            withForeignPtr fp3 $ \p3 ->
            go (plusPtr p1 off1) (plusPtr p2 off2) p3 (n1-1)
        return $ SVector_Dynamic fp3 0 n1

    where
        go _ _ _ (-1) = return ()
        go p1 p2 p3 i = do
            v1 <- peekElemOff p1 i
            v2 <- peekElemOff p2 i
            pokeElemOff p3 i (f v1 v2)
            go p1 p2 p3 (i-1)

{-# INLINE monopDyn #-}
monopDyn :: forall a b n m.
    ( Storable a
    ) => (a -> a) -> SVector (n::Symbol) a -> SVector (n::Symbol) a
monopDyn f v@(SVector_Dynamic fp1 off1 n) = if isNull fp1
    then v
    else unsafeInlineIO $ do
        let b = n*sizeOf (undefined::a)
        fp2 <- mallocForeignPtrBytes b
        withForeignPtr fp1 $ \p1 ->
            withForeignPtr fp2 $ \p2 ->
                go (plusPtr p1 off1) p2 (n-1)
        return $ SVector_Dynamic fp2 0 n

    where
        go _ _ (-1) = return ()
        go p1 p2 i = do
            v1 <- peekElemOff p1 i
            pokeElemOff p2 i (f v1)
            go p1 p2 (i-1)

{-# INLINE binopDynM #-}
binopDynM :: forall a b n m.
    ( PrimBase m
    , Storable a
    , Storable b
    , Monoid a
    , Monoid b
    ) => (a -> b -> a) -> Mutable m (SVector (n::Symbol) a) -> SVector n b -> m ()
binopDynM f (Mutable_SVector ref) (SVector_Dynamic fp2 off2 n2) = do
    (SVector_Dynamic fp1 off1 n1) <- readPrimRef ref

    let runop fp1 fp2 n = unsafePrimToPrim $
            withForeignPtr fp1 $ \p1 ->
            withForeignPtr fp2 $ \p2 ->
                go (plusPtr p1 off1) (plusPtr p2 off2) (n-1)

    unsafePrimToPrim $ if
        -- both vectors are zero: do nothing
        | isNull fp1 && isNull fp2 -> return ()

        -- only left vector is zero: allocate space and overwrite old vector
        -- FIXME: this algorithm requires two passes over the left vector
        | isNull fp1 -> do
            fp1' <- zerofp n2
            unsafePrimToPrim $ writePrimRef ref (SVector_Dynamic fp1' 0 n2)
            runop fp1' fp2 n2

        -- only right vector is zero: use a temporary zero vector to run like normal
        -- FIXME: this algorithm requires an unneeded memory allocation and memory pass
        | isNull fp2 -> do
            fp2' <- zerofp n1
            runop fp1 fp2' n1

        -- both vectors nonzero: run like normal
        | otherwise -> runop fp1 fp2 n1

    where
        go _ _ (-1) = return ()
        go p1 p2 i = do
            v1 <- peekElemOff p1 i
            v2 <- peekElemOff p2 i
            pokeElemOff p1 i (f v1 v2)
            go p1 p2 (i-1)

{-# INLINE monopDynM #-}
monopDynM :: forall a b n m.
    ( PrimMonad m
    , Storable a
    ) => (a -> a) -> Mutable m (SVector (n::Symbol) a) -> m ()
monopDynM f (Mutable_SVector ref) = do
    (SVector_Dynamic fp1 off1 n) <- readPrimRef ref
    if isNull fp1
        then return ()
        else unsafePrimToPrim $
            withForeignPtr fp1 $ \p1 ->
                go (plusPtr p1 off1) (n-1)

    where
        go _ (-1) = return ()
        go p1 i = do
            v1 <- peekElemOff p1 i
            pokeElemOff p1 i (f v1)
            go p1 (i-1)

-------------------

instance (Monoid r, Storable r) => Semigroup (SVector (n::Symbol) r) where
    {-# INLINE (+)  #-} ; (+)  = binopDyn  (+)
    {-# INLINE (+=) #-} ; (+=) = binopDynM (+)

instance (Monoid r, Cancellative r, Storable r) => Cancellative (SVector (n::Symbol) r) where
    {-# INLINE (-)  #-} ; (-)  = binopDyn  (-)
    {-# INLINE (-=) #-} ; (-=) = binopDynM (-)

instance (Monoid r, Storable r) => Monoid (SVector (n::Symbol) r) where
    {-# INLINE zero #-}
    zero = SVector_Dynamic (unsafeInlineIO $ newForeignPtr_ nullPtr) 0 0

instance (Group r, Storable r) => Group (SVector (n::Symbol) r) where
    {-# INLINE negate #-}
    negate v = unsafeInlineIO $ do
        mv <- thaw v
        monopDynM negate mv
        unsafeFreeze mv

instance (Monoid r, Abelian r, Storable r) => Abelian (SVector (n::Symbol) r)

instance (Module r, Storable r) => Module (SVector (n::Symbol) r) where
    {-# INLINE (.*)   #-} ;  (.*)  v r = monopDyn  (.*r) v
    {-# INLINE (.*=)  #-} ;  (.*=) v r = monopDynM (.*r) v

instance (FreeModule r, Storable r) => FreeModule (SVector (n::Symbol) r) where
    {-# INLINE (.*.)  #-} ;  (.*.)     = binopDyn  (.*.)
    {-# INLINE (.*.=) #-} ;  (.*.=)    = binopDynM (.*.)

instance (VectorSpace r, Storable r) => VectorSpace (SVector (n::Symbol) r) where
    {-# INLINE (./)   #-} ;  (./)  v r = monopDyn  (./r) v
    {-# INLINE (./=)  #-} ;  (./=) v r = monopDynM (./r) v

    {-# INLINE (./.)  #-} ;  (./.)     = binopDyn  (./.)
    {-# INLINE (./.=) #-} ;  (./.=)    = binopDynM (./.)

----------------------------------------
-- container

instance (Monoid r, ValidLogic r, Storable r, IsScalar r) => IxContainer (SVector (n::Symbol) r) where

    {-# INLINE (!) #-}
    (!) (SVector_Dynamic fp off n) i = unsafeInlineIO $ withForeignPtr fp $ \p -> peekElemOff p (off+i)


instance (FreeModule r, ValidLogic r, Storable r, IsScalar r) => FiniteModule (SVector (n::Symbol) r) where

    {-# INLINE dim #-}
    dim (SVector_Dynamic _ _ n) = n

    {-# INLINABLE unsafeToModule #-}
    unsafeToModule xs = unsafeInlineIO $ do
        fp <- mallocForeignPtrArray n
        withForeignPtr fp $ \p -> go p (P.reverse xs) (n-1)
        return $ SVector_Dynamic fp 0 n

        where
            n = length xs

            go p []  (-1) = return ()
            go p (x:xs) i = do
                pokeElemOff p i x
                go p xs (i-1)

----------------------------------------
-- comparison

instance (Eq r, Monoid r, Storable r) => Eq_ (SVector (n::Symbol) r) where
    {-# INLINE (==) #-}
    (SVector_Dynamic fp1 off1 n1)==(SVector_Dynamic fp2 off2 n2) = unsafeInlineIO $ if
        | isNull fp1 && isNull fp2 -> return true
        | isNull fp1 -> withForeignPtr fp2 $ \p -> checkZero (plusPtr p off2) (n2-1)
        | isNull fp2 -> withForeignPtr fp1 $ \p -> checkZero (plusPtr p off1) (n1-1)
        | otherwise ->
            withForeignPtr fp1 $ \p1 ->
            withForeignPtr fp2 $ \p2 ->
                outer (plusPtr p1 off1) (plusPtr p2 off2) (n1-1)
        where
            checkZero :: Ptr r -> Int -> IO Bool
            checkZero p (-1) = return true
            checkZero p i = do
                x <- peekElemOff p i
                if isZero x
                    then checkZero p (-1)
                    else return false

            outer :: Ptr r -> Ptr r -> Int -> IO Bool
            outer p1 p2 = go
                where
                    go (-1) = return true
                    go i = do
                        v1 <- peekElemOff p1 i
                        v2 <- peekElemOff p2 i
                        next <- go (i-1)
                        return $ v1==v2 && next

{-


{-# INLINE innerp #-}
-- innerp :: SVector 200 Float -> SVector 200 Float -> Float
innerp v1 v2 = go 0 (n-1)

    where
        n = 200
--         n = nat2int (Proxy::Proxy n)

        go !tot !i =  if i<4
            then goEach tot i
            else
                go (tot+(v1!(i  ) * v2!(i  ))
                       +(v1!(i-1) * v2!(i-1))
                       +(v1!(i-2) * v2!(i-2))
                       +(v1!(i-3) * v2!(i-3))
                   ) (i-4)

        goEach !tot !i = if i<0
            then tot
            else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)

----------------------------------------
-- distances
-}
instance
    ( Storable r
    , ExpField r
    , Normed r
    , Ord_ r
    , Logic r~Bool
    , IsScalar r
    , VectorSpace r
    ) => Metric (SVector (n::Symbol) r)
        where

    {-# INLINE[2] distance #-}
    distance v1@(SVector_Dynamic fp1 _ n) v2@(SVector_Dynamic fp2 _ _) = {-# SCC distance_SVector #-} if
        | isNull fp1 -> size v2
        | isNull fp2 -> size v1
        | otherwise -> sqrt $ go 0 (n-1)
        where
            go !tot !i =  if i<4
                then goEach tot i
                else go (tot+(v1!(i  ) - v2!(i  )) .*. (v1!(i  ) - v2!(i  ))
                            +(v1!(i-1) - v2!(i-1)) .*. (v1!(i-1) - v2!(i-1))
                            +(v1!(i-2) - v2!(i-2)) .*. (v1!(i-2) - v2!(i-2))
                            +(v1!(i-3) - v2!(i-3)) .*. (v1!(i-3) - v2!(i-3))
                        ) (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)

    {-# INLINE[2] distanceUB #-}
    distanceUB v1@(SVector_Dynamic fp1 _ n) v2@(SVector_Dynamic fp2 _ _) ub = {-# SCC distanceUB_SVector #-}if
        | isNull fp1 -> size v2
        | isNull fp2 -> size v1
        | otherwise -> sqrt $ go 0 (n-1)
        where
            ub2=ub*ub

            go !tot !i = if tot>ub2
                then tot
                else if i<4
                    then goEach tot i
                    else go (tot+(v1!(i  ) - v2!(i  )) .*. (v1!(i  ) - v2!(i  ))
                                +(v1!(i-1) - v2!(i-1)) .*. (v1!(i-1) - v2!(i-1))
                                +(v1!(i-2) - v2!(i-2)) .*. (v1!(i-2) - v2!(i-2))
                                +(v1!(i-3) - v2!(i-3)) .*. (v1!(i-3) - v2!(i-3))
                            ) (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)

instance (VectorSpace r, Storable r, IsScalar r, ExpField r) => Normed (SVector (n::Symbol) r) where
    {-# INLINE size #-}
    size v@(SVector_Dynamic fp _ n) = if isNull fp
        then 0
        else  sqrt $ go 0 (n-1)
        where
            go !tot !i =  if i<4
                then goEach tot i
                else go (tot+v!(i  ).*.v!(i  )
                            +v!(i-1).*.v!(i-1)
                            +v!(i-2).*.v!(i-2)
                            +v!(i-3).*.v!(i-3)
                        ) (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot+v!i*v!i) (i-1)


--------------------------------------------------------------------------------

newtype instance SVector (n::Nat) r = SVector_Nat (ForeignPtr r)

instance (Show r, Storable r, KnownNat n) => Show (SVector n  r) where
    show v = show (vec2list v)
        where
            n = nat2int (Proxy::Proxy n)

            vec2list (SVector_Nat fp) = unsafeInlineIO $ go (n-1) []
                where
                    go (-1) xs = return $ xs
                    go i    xs = withForeignPtr fp $ \p -> do
                        x <- peekElemOff p i
                        go (i-1) (x:xs)

instance
    ( KnownNat n
    , Arbitrary r
    , Storable r
    , FreeModule r
    , IsScalar r
    ) => Arbitrary (SVector (n::Nat) r)
        where
    arbitrary = do
        xs <- replicateM n arbitrary
        return $ unsafeToModule xs
        where
            n = nat2int (Proxy::Proxy n)

instance (NFData r, Storable r) => NFData (SVector (n::Nat) r) where
    rnf (SVector_Nat fp) = seq fp ()

static2dynamic :: forall n m r. KnownNat n => SVector (n::Nat) r -> SVector (m::Symbol) r
static2dynamic (SVector_Nat fp) = SVector_Dynamic fp 0 $ nat2int (Proxy::Proxy n)

--------------------

newtype instance Mutable m (SVector (n::Nat) r) = Mutable_SVector_Nat (ForeignPtr r)

instance (KnownNat n, Storable r) => IsMutable (SVector (n::Nat) r) where
    freeze mv = copy mv >>= unsafeFreeze
    thaw v = unsafeThaw v >>= copy

    unsafeFreeze (Mutable_SVector_Nat fp) = return $ SVector_Nat fp
    unsafeThaw (SVector_Nat fp) = return $ Mutable_SVector_Nat fp

    copy (Mutable_SVector_Nat fp1) = unsafePrimToPrim $ do
        fp2 <- mallocForeignPtrBytes b
        withForeignPtr fp1 $ \p1 -> withForeignPtr fp2 $ \p2 -> copyBytes p2 p1 b
        return (Mutable_SVector_Nat fp2)

        where
            n = nat2int (Proxy::Proxy n)
            b = n*sizeOf (undefined::r)

    write (Mutable_SVector_Nat fp1) (SVector_Nat fp2) = unsafePrimToPrim $
        withForeignPtr fp1 $ \p1 ->
        withForeignPtr fp2 $ \p2 ->
            copyBytes p1 p2 b

        where
            n = nat2int (Proxy::Proxy n)
            b = n*sizeOf (undefined::r)

----------------------------------------
-- algebra

{-# INLINE binopStatic #-}
binopStatic :: forall a b n m.
    ( Storable a
    , KnownNat n
    ) => (a -> a -> a) -> SVector n a -> SVector n a -> SVector n a
binopStatic f v1@(SVector_Nat fp1) v2@(SVector_Nat fp2) = unsafeInlineIO $ do
    fp3 <- mallocForeignPtrBytes b
    withForeignPtr fp1 $ \p1 ->
        withForeignPtr fp2 $ \p2 ->
        withForeignPtr fp3 $ \p3 ->
        go p1 p2 p3 (n-1)
    return $ SVector_Nat fp3

    where
        n = nat2int (Proxy::Proxy n)
        b = n*sizeOf (undefined::a)

        go _ _ _ (-1) = return ()
        go p1 p2 p3 i = do
            x0 <- peekElemOff p1 i
--             x1 <- peekElemOff p1 (i-1)
--             x2 <- peekElemOff p1 (i-2)
--             x3 <- peekElemOff p1 (i-3)

            y0 <- peekElemOff p2 i
--             y1 <- peekElemOff p2 (i-1)
--             y2 <- peekElemOff p2 (i-2)
--             y3 <- peekElemOff p2 (i-3)

            pokeElemOff p3 i     (f x0 y0)
--             pokeElemOff p3 (i-1) (f x1 y1)
--             pokeElemOff p3 (i-2) (f x2 y2)
--             pokeElemOff p3 (i-3) (f x3 y3)

            go p1 p2 p3 (i-1)
--             go p1 p2 p3 (i-4)

{-# INLINE monopStatic #-}
monopStatic :: forall a b n m.
    ( Storable a
    , KnownNat n
    ) => (a -> a) -> SVector n a -> SVector n a
monopStatic f v@(SVector_Nat fp1) = unsafeInlineIO $ do
    fp2 <- mallocForeignPtrBytes b
    withForeignPtr fp1 $ \p1 ->
        withForeignPtr fp2 $ \p2 ->
            go p1 p2 (n-1)
    return $ SVector_Nat fp2

    where
        n = nat2int (Proxy::Proxy n)
        b = n*sizeOf (undefined::a)

        go _ _ (-1) = return ()
        go p1 p2 i = do
            v1 <- peekElemOff p1 i
            pokeElemOff p2 i (f v1)
            go p1 p2 (i-1)

{-# INLINE binopStaticM #-}
binopStaticM :: forall a b n m.
    ( PrimMonad m
    , Storable a
    , Storable b
    , KnownNat n
    ) => (a -> b -> a) -> Mutable m (SVector n a) -> SVector n b -> m ()
binopStaticM f (Mutable_SVector_Nat fp1) (SVector_Nat fp2) = unsafePrimToPrim $
    withForeignPtr fp1 $ \p1 ->
    withForeignPtr fp2 $ \p2 ->
        go p1 p2 (n-1)

    where
        n = nat2int (Proxy::Proxy n)

        go _ _ (-1) = return ()
        go p1 p2 i = do
            v1 <- peekElemOff p1 i
            v2 <- peekElemOff p2 i
            pokeElemOff p1 i (f v1 v2)
            go p1 p2 (i-1)

{-# INLINE monopStaticM #-}
monopStaticM :: forall a b n m.
    ( PrimMonad m
    , Storable a
    , KnownNat n
    ) => (a -> a) -> Mutable m (SVector n a) -> m ()
monopStaticM f (Mutable_SVector_Nat fp1)  = unsafePrimToPrim $
    withForeignPtr fp1 $ \p1 ->
        go p1 (n-1)

    where
        n = nat2int (Proxy::Proxy n)

        go _ (-1) = return ()
        go p1 i = do
            v1 <- peekElemOff p1 i
            pokeElemOff p1 i (f v1)
            go p1 (i-1)

-------------------

instance (KnownNat n, Semigroup r, Storable r) => Semigroup (SVector (n::Nat) r) where
    {-# INLINE (+)  #-} ; (+)  = binopStatic  (+)
    {-# INLINE (+=) #-} ; (+=) = binopStaticM (+)

instance (KnownNat n, Cancellative r, Storable r) => Cancellative (SVector (n::Nat) r) where
    {-# INLINE (-)  #-} ; (-)  = binopStatic  (-)
    {-# INLINE (-=) #-} ; (-=) = binopStaticM (-)

instance (KnownNat n, Monoid r, Storable r) => Monoid (SVector (n::Nat) r) where
    {-# INLINE zero #-}
    zero = unsafeInlineIO $ do
        mv <- fmap (\fp -> Mutable_SVector_Nat fp) $ mallocForeignPtrArray n
        monopStaticM (const zero) mv
        unsafeFreeze mv
        where
            n = nat2int (Proxy::Proxy n)

instance (KnownNat n, Group r, Storable r) => Group (SVector (n::Nat) r) where
    {-# INLINE negate #-}
    negate v = unsafeInlineIO $ do
        mv <- thaw v
        monopStaticM negate mv
        unsafeFreeze mv

instance (KnownNat n, Abelian r, Storable r) => Abelian (SVector (n::Nat) r)

instance (KnownNat n, Module r, Storable r) => Module (SVector (n::Nat) r) where
    {-# INLINE (.*)   #-} ;  (.*)  v r = monopStatic  (.*r) v
    {-# INLINE (.*=)  #-} ;  (.*=) v r = monopStaticM (.*r) v

instance (KnownNat n, FreeModule r, Storable r) => FreeModule (SVector (n::Nat) r) where
    {-# INLINE (.*.)  #-} ;  (.*.)     = binopStatic  (.*.)
    {-# INLINE (.*.=) #-} ;  (.*.=)    = binopStaticM (.*.)

instance (KnownNat n, VectorSpace r, Storable r) => VectorSpace (SVector (n::Nat) r) where
    {-# INLINE (./)   #-} ;  (./)  v r = monopStatic  (./r) v
    {-# INLINE (./=)  #-} ;  (./=) v r = monopStaticM (./r) v

    {-# INLINE (./.)  #-} ;  (./.)     = binopStatic  (./.)
    {-# INLINE (./.=) #-} ;  (./.=)    = binopStaticM (./.)

----------------------------------------
-- "container"

instance
    ( KnownNat n
    , Monoid r
    , ValidLogic r
    , Storable r
    , IsScalar r
    ) => IxContainer (SVector (n::Nat) r)
        where

    {-# INLINE (!) #-}
    (!) (SVector_Nat fp) i = unsafeInlineIO $ withForeignPtr fp $ \p -> peekElemOff p i


instance
    ( KnownNat n
    , FreeModule r
    , ValidLogic r
    , Storable r
    , IsScalar r
    ) => FiniteModule (SVector (n::Nat) r)
        where

    {-# INLINE dim #-}
    dim v = nat2int (Proxy::Proxy n)

    {-# INLINABLE unsafeToModule #-}
    unsafeToModule xs = if n /= length xs
        then error "unsafeToModule size mismatch"
        else unsafeInlineIO $ do
            fp <- mallocForeignPtrArray n
            withForeignPtr fp $ \p -> go p (P.reverse xs) (n-1)
            return $ SVector_Nat fp

        where
            n = nat2int (Proxy::Proxy n)

            go p []  (-1) = return ()
            go p (x:xs) i = do
                pokeElemOff p i x
                go p xs (i-1)


----------------------------------------
-- comparison

instance (KnownNat n, Eq_ r, ValidLogic r, Storable r) => Eq_ (SVector (n::Nat) r) where
    {-# INLINE (==) #-}
    (SVector_Nat fp1)==(SVector_Nat fp2) = unsafeInlineIO $
        withForeignPtr fp1 $ \p1 ->
        withForeignPtr fp2 $ \p2 ->
            outer p1 p2 (n-1)
        where
            n = nat2int (Proxy::Proxy n)

            outer p1 p2 = go
                where
                    go (-1) = return true
                    go i = do
                        v1 <- peekElemOff p1 i
                        v2 <- peekElemOff p2 i
                        next <- go (i-1)
                        return $ v1==v2 && next

{-# INLINE innerp #-}
-- innerp :: SVector 200 Float -> SVector 200 Float -> Float
innerp v1 v2 = go 0 (n-1)

    where
        n = 200
--         n = nat2int (Proxy::Proxy n)

        go !tot !i =  if i<4
            then goEach tot i
            else
                go (tot+(v1!(i  ) * v2!(i  ))
                       +(v1!(i-1) * v2!(i-1))
                       +(v1!(i-2) * v2!(i-2))
                       +(v1!(i-3) * v2!(i-3))
                   ) (i-4)

        goEach !tot !i = if i<0
            then tot
            else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)

----------------------------------------
-- distances

instance
    ( KnownNat n
    , Storable r
    , ExpField r
    , Normed r
    , Ord_ r
    , Logic r~Bool
    , IsScalar r
    , VectorSpace r
    ) => Metric (SVector (n::Nat) r)
        where

    -- For some reason, using the dynamic vector is a little faster than a straight implementation
    {-# INLINE[2] distance #-}
    distance v1 v2 = distance (static2dynamic v1) (static2dynamic v2)
--     distance v1 v2 = sqrt $ go 0 (n-1)
--         where
--             n = nat2int (Proxy::Proxy n)
--
--             go !tot !i =  if i<4
--                 then goEach tot i
--                 else go (tot+(v1!(i  ) - v2!(i  )) .*. (v1!(i  ) - v2!(i  ))
--                             +(v1!(i-1) - v2!(i-1)) .*. (v1!(i-1) - v2!(i-1))
--                             +(v1!(i-2) - v2!(i-2)) .*. (v1!(i-2) - v2!(i-2))
--                             +(v1!(i-3) - v2!(i-3)) .*. (v1!(i-3) - v2!(i-3))
--                         ) (i-4)
--
--             goEach !tot !i = if i<0
--                 then tot
--                 else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)

    {-# INLINE[2] distanceUB #-}
    distanceUB v1 v2 ub = {-# SCC distanceUB_SVector #-} sqrt $ go 0 (n-1)
        where
            n = nat2int (Proxy::Proxy n)
            ub2 = ub*ub

            go !tot !i = if tot>ub2
                then tot
                else if i<4
                    then goEach tot i
                    else go (tot+(v1!(i  ) - v2!(i  )) .*. (v1!(i  ) - v2!(i  ))
                                +(v1!(i-1) - v2!(i-1)) .*. (v1!(i-1) - v2!(i-1))
                                +(v1!(i-2) - v2!(i-2)) .*. (v1!(i-2) - v2!(i-2))
                                +(v1!(i-3) - v2!(i-3)) .*. (v1!(i-3) - v2!(i-3))
                            ) (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot+(v1!i - v2!i) * (v1!i - v2!i)) (i-1)

instance
    ( KnownNat n
    , VectorSpace r
    , Storable r
    , IsScalar r
    , ExpField r
    ) => Normed (SVector (n::Nat) r)
        where
    {-# INLINE size #-}
    size v = sqrt $ go 0 (n-1)
        where
            n = nat2int (Proxy::Proxy n)

            go !tot !i =  if i<4
                then goEach tot i
                else go (tot+v!(i  ) .*. v!(i  )
                            +v!(i-1) .*. v!(i-1)
                            +v!(i-2) .*. v!(i-2)
                            +v!(i-3) .*. v!(i-3)
                        ) (i-4)

            goEach !tot !i = if i<0
                then tot
                else goEach (tot+v!i*v!i) (i-1)

--------------------------------------------------------------------------------
-- rewrite rules for faster static parameters
--
-- FIXME: Find a better home for this.
--
-- FIXME: Expand to many more naturals.

{-# INLINE[2] nat2int #-}
nat2int :: KnownNat n => Proxy n -> Int
nat2int = fromIntegral . natVal

{-# INLINE[1] nat200 #-}
nat200 :: Proxy 200 -> Int
nat200 _ = 200

{-# RULES

"subhask/nat2int_200" nat2int = nat200

  #-}

