{-# LANGUAGE ExplicitForAll         #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE PolyKinds              #-}
{-# EXT      InlineAll              #-}

module Control.Monad.State.Dependent where

import Prelude

import Control.Applicative
import Control.Lens
import Control.Lens.Utils
import Control.Monad.Catch
import Control.Monad.Fail
import Control.Monad.Identity
import Control.Monad.IO.Class
import Control.Monad.Primitive
import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import Data.Constraint
import Data.Default
import Type.Bool
import qualified Control.Monad.State as S

-----------------------------
-- === Dependent State === --
-----------------------------

-- === Definition === --

type    State  s     = StateT s Identity
newtype StateT s m a = StateT (S.StateT s m a) deriving (Applicative, Alternative, Functor, Monad, MonadFail, MonadFix, MonadIO, MonadPlus, MonadTrans, MonadThrow)
makeWrapped ''StateT

type        States  ss = StatesT ss Identity
type family StatesT ss m where
    StatesT '[]       m = m
    StatesT (s ': ss) m = StateT s (StatesT ss m)


-- === Running === --

runStateT  :: forall s m a. Monad m => StateT s m a -> s -> m (a, s)
evalStateT :: forall s m a. Monad m => StateT s m a -> s -> m a
execStateT :: forall s m a. Monad m => StateT s m a -> s -> m s
runStateT  = S.runStateT  . unwrap
evalStateT = S.evalStateT . unwrap
execStateT = S.execStateT . unwrap

runDefStateT  :: forall s m a. (Monad m, Default s) => StateT s m a -> m (a, s)
evalDefStateT :: forall s m a. (Monad m, Default s) => StateT s m a -> m a
execDefStateT :: forall s m a. (Monad m, Default s) => StateT s m a -> m s
runDefStateT  = flip runStateT  def
evalDefStateT = flip evalStateT def
execDefStateT = flip execStateT def

runState  :: forall s a. State s a -> s -> (a, s)
evalState :: forall s a. State s a -> s -> a
execState :: forall s a. State s a -> s -> s
runState  = S.runState  . unwrap
evalState = S.evalState . unwrap
execState = S.execState . unwrap

runDefState  :: forall s a. Default s => State s a -> (a, s)
evalDefState :: forall s a. Default s => State s a -> a
execDefState :: forall s a. Default s => State s a -> s
runDefState  = flip runState  def
evalDefState = flip evalState def
execDefState = flip execState def


-- === MonadState === --

type MonadState s m = (MonadGetter s m, MonadSetter s m)

class Monad m => MonadGetter s m where
    get' :: m s
    default get' :: (m ~ t n, MonadTrans t, Monad n, MonadGetter s n) => m s
    get' = lift get'

class Monad m => MonadSetter s m where
    put' :: s -> m ()
    default put' :: (m ~ t n, MonadTrans t, Monad n, MonadSetter s n) => s -> m ()
    put' = lift . put'

type family MonadGetters ss m :: Constraint where
    MonadGetters '[]       m = ()
    MonadGetters (s ': ss) m = (MonadGetter s m, MonadGetters ss m)

type family MonadSetters ss m :: Constraint where
    MonadSetters '[]       m = ()
    MonadSetters (s ': ss) m = (MonadSetter s m, MonadSetters ss m)

type family MonadStates ss m :: Constraint where
    MonadStates '[]       m = ()
    MonadStates (s ': ss) m = (MonadState s m, MonadStates ss m)


-- === State inference === --

type MonadGetter' t s m = (InferState t m s, MonadGetter s m)
type MonadSetter' t s m = (InferState t m s, MonadSetter s m)
type MonadState'  t s m = (InferState t m s, MonadState  s m)

class InferState (t :: k) (m :: * -> *) (s :: *) | t m -> s
instance {-# OVERLAPPABLE #-} InferSubState (DiscoverMonad m) st st'
      => InferState (st :: k -> k') m st'
instance InferState (st :: *)       m st

class InferSubState (p :: Either (*,* -> *) (* -> *)) (t :: k) (s :: *) | p t -> s
instance InferState st m st'                        => InferSubState ('Right m)     st st'
instance InferState' (MatchedBases st s) s st m st' => InferSubState ('Left '(s,m)) st st'

class InferState' (b :: Bool) (ps :: *) (t :: k) (m :: * -> *) (s :: *) | b ps t m -> s
instance                        InferState' 'True  ps st m ps
instance InferState st m st' => InferState' 'False ps st m st'

type family DiscoverMonad m where
    DiscoverMonad (StateT s m) = 'Left '(s, m)
    DiscoverMonad (t        m) = 'Right m

type family MatchedBases (a :: ka) (b :: kb) :: Bool where
    MatchedBases (a :: k) (b   :: k) = a == b
    MatchedBases (a :: k) (b t :: l) = MatchedBases a b
    MatchedBases (a :: k) (b   :: l) = 'False


-- === Singleton state inference === --

type MonadGetter_ s m = (s ~ GetFirstState m, MonadGetter s m)
type MonadSetter_ s m = (s ~ GetFirstState m, MonadSetter s m)
type MonadState_  s m = (s ~ GetFirstState m, MonadState  s m)

type family GetFirstState (m :: * -> *) where
    GetFirstState (StateT s m) = s
    GetFirstState (t m)        = GetFirstState m


-- === Modification of raw state === --

modifyM'  :: forall s m a. MonadState s m => (s -> m (a, s)) -> m a
modifyM'_ :: forall s m a. MonadState s m => (s -> m     s)  -> m ()
modify'   :: forall s m a. MonadState s m => (s ->   (a, s)) -> m a
modify'_  :: forall s m a. MonadState s m => (s ->       s)  -> m ()
modify'    = modifyM'  . fmap return
modify'_   = modifyM'_ . fmap return
modifyM'_  = modifyM'  . (fmap.fmap) ((),)
modifyM' f = do (a,t) <- f =<< get'
                a <$ put' t

branched'      :: forall s m a. MonadState s m =>               m a -> m a
with'          :: forall s m a. MonadState s m => s          -> m a -> m a
withModified'  :: forall s m a. MonadState s m => (s ->   s) -> m a -> m a
withModifiedM' :: forall s m a. MonadState s m => (s -> m s) -> m a -> m a
with'              = withModified'  . const
withModified'      = withModifiedM' . fmap return
withModifiedM' f m = branched' @s $ modifyM'_ f >> m
branched'        m = do s <- get' @s
                        m <* put' @s s


-- === Modification of inferred state === --

get :: forall t s m. MonadGetter' t s m => m s
put :: forall t s m. MonadSetter' t s m => s -> m ()
get = get' @s
put = put' @s

modifyM  :: forall t s m a. MonadState' t s m => (s -> m (a, s)) -> m a
modifyM_ :: forall t s m a. MonadState' t s m => (s -> m     s)  -> m ()
modify   :: forall t s m a. MonadState' t s m => (s ->   (a, s)) -> m a
modify_  :: forall t s m a. MonadState' t s m => (s ->       s)  -> m ()
modify   = modify'   @s
modify_  = modify'_  @s
modifyM_ = modifyM'_ @s
modifyM  = modifyM'  @s

branched      :: forall t s m a. MonadState' t s m =>               m a -> m a
with          :: forall t s m a. MonadState' t s m => s          -> m a -> m a
withModified  :: forall t s m a. MonadState' t s m => (s ->   s) -> m a -> m a
withModifiedM :: forall t s m a. MonadState' t s m => (s -> m s) -> m a -> m a
branched      = branched'      @s
with          = with'          @s
withModified  = withModified'  @s
withModifiedM = withModifiedM' @s


-- === Modification of inferred singleton state === --

_get :: forall s m. MonadGetter_ s m => m s
_put :: forall s m. MonadSetter_ s m => s -> m ()
_get = get' @s
_put = put' @s

_modifyM  :: forall s m a. MonadState_ s m => (s -> m (a, s)) -> m a
_modifyM_ :: forall s m a. MonadState_ s m => (s -> m     s)  -> m ()
_modify   :: forall s m a. MonadState_ s m => (s ->   (a, s)) -> m a
_modify_  :: forall s m a. MonadState_ s m => (s ->       s)  -> m ()
_modify   = modify'   @s
_modify_  = modify'_  @s
_modifyM_ = modifyM'_ @s
_modifyM  = modifyM'  @s

_branched      :: forall s m a. MonadState_ s m =>               m a -> m a
_with          :: forall s m a. MonadState_ s m => s          -> m a -> m a
_withModified  :: forall s m a. MonadState_ s m => (s ->   s) -> m a -> m a
_withModifiedM :: forall s m a. MonadState_ s m => (s -> m s) -> m a -> m a
_branched      = branched'      @s
_with          = with'          @s
_withModified  = withModified'  @s
_withModifiedM = withModifiedM' @s


-- === Instances === --

-- Matching the right state
instance {-# OVERLAPPABLE #-} MonadGetter s m => MonadGetter s (StateT s' m)
instance {-# OVERLAPPABLE #-} MonadSetter s m => MonadSetter s (StateT s' m)
instance                      Monad m         => MonadGetter s (StateT s  m) where get' = wrap   S.get
instance                      Monad m         => MonadSetter s (StateT s  m) where put' = wrap . S.put

-- Primitive
instance PrimMonad m => PrimMonad (StateT s m) where
    type PrimState (StateT s m) = PrimState m
    primitive = lift . primitive


-- === Std types instances === --

instance MonadGetter s m => MonadGetter s (S.StateT s' m)
instance MonadSetter s m => MonadSetter s (S.StateT s' m)

instance MonadGetter s m => MonadGetter s (MaybeT m)
instance MonadSetter s m => MonadSetter s (MaybeT m)
