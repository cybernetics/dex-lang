{-# LANGUAGE OverloadedStrings #-}

module JIT (jitPass, PersistVal, PersistType) where

import Control.Monad
import Control.Monad.Except (throwError)
import Control.Monad.Reader (ReaderT, runReaderT, local, ask, asks)
import Control.Monad.State (StateT, runStateT, put, get, gets, modify)
import Control.Applicative (liftA, liftA2, liftA3)
import Data.IORef

import qualified Data.Map.Strict as M
import Data.Foldable (toList)
import Data.List (intercalate, transpose)
import Data.Traversable
import Data.Functor.Identity

import qualified LLVM.AST as L
import qualified LLVM.AST.Type as L
import qualified LLVM.AST.Operand as Op
import qualified LLVM.AST.Global as L
import qualified LLVM.AST.Float as L
import qualified LLVM.AST.IntegerPredicate as L
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.CallingConvention as L
import qualified LLVM.Module as Mod
import qualified LLVM.Analysis as Mod
import qualified LLVM.ExecutionEngine as EE
import LLVM.Internal.Context
-- import LLVM.Pretty (ppllvm)

import Data.Int
import Foreign.Ptr hiding (Ptr)
import Foreign.Storable

import qualified Foreign.Ptr as F
import qualified Data.Text.Lazy as DT
import Data.ByteString.Char8 (unpack)
import Data.ByteString.Short (ShortByteString)
import Data.Word (Word64 (..))

import Data.Time.Clock (getCurrentTime, diffUTCTime)

import Type
import Syntax
import Env
import Record
import Util

foreign import ccall "dynamic"
  haskFun :: FunPtr (IO (F.Ptr ())) -> IO (F.Ptr ())

type Compiled = L.Module
type JitEnv w = FullEnv (JitVal w) (JitType w)

data JitType w = JitType Type [w]  deriving (Show)

data JitVal w = ScalarVal BaseType w
              | IdxVal w w
              | TabVal (Table w)
              | RecVal (Record (JitVal w))
              | ExPackage w (JitVal w)  deriving (Show)

data PWord = PScalar BaseType Word64
           | PPtr    BaseType (F.Ptr ())  deriving (Show)

type CompileVal  = JitVal  Operand
type CompileType = JitType Operand
type CompileEnv  = JitEnv  Operand

type PersistVal  = JitVal  PWord
type PersistType = JitType PWord
type PersistEnv  = JitEnv  PWord

data Table w = Table (Ptr w) w (Sizes w) (JitType w) deriving (Show)
data Sizes w = ConstSize w | ManySizes (Ptr w)       deriving (Show)
data Ptr w = Ptr w                                   deriving (Show)

type CTable = Table Operand
type CSizes = Sizes Operand
type CPtr   = Ptr Operand

type BString = ShortByteString
type Operand = L.Operand
type Block = L.BasicBlock
type Instr = L.Named L.Instruction

type Long     = Operand
type Index    = Operand
type NumElems = Operand

type CompileApp  = [CompileType] -> [CompileVal] -> CompileM CompileVal

data CompileState = CompileState { nameCounter :: Int
                                 , curBlocks :: [Block]
                                 , curInstrs :: [Instr]
                                 , varDecls  :: [Instr]
                                 , curBlockName :: L.Name }

data ExternFunSpec = ExternFunSpec BString L.Type [L.Type] [BString]

type CompileM a = ReaderT CompileEnv (StateT CompileState (Either Err)) a

jitPass :: Pass Expr () PersistVal PersistType
jitPass = Pass jitExpr jitUnpack jitCmd

jitExpr :: Expr -> PersistEnv -> IO (PersistVal, ())
jitExpr expr env = do let (v, m) = lower expr env
                      val <- uncurry evalJit (lower expr env)
                      return (val, ())

jitUnpack :: VarName -> Expr -> PersistEnv -> IO (PersistVal, PersistType, ())
jitUnpack _ expr env = undefined -- do let (v, m) = lower expr env
                          -- ExPackage i val <- uncurry evalJit (lower expr env)
                          -- return (val, Meta i, ())

jitCmd :: Command Expr -> PersistEnv -> IO (Command ())
jitCmd (Command cmdName expr) env =
  case cmdName of
    GetLLVM ->  liftM textResult $ showLLVM m
    EvalExpr -> do val <- evalJit v m
                   liftM textResult $ printPersistVal val
    ShowPersistVal -> do val <- evalJit v m
                         return $ textResult (show val)
    TimeIt -> do t1 <- getCurrentTime
                 ans <- evalJit v m
                 t2 <- getCurrentTime
                 return $ textResult $ show (t2 `diffUTCTime` t1)
    Plot -> do val <- evalJit v m
               (xs, ys) <- makePlot val
               return $ CmdResult $ PlotOut xs ys
    PlotMat -> do val <- evalJit v m
                  zs <- makePlotMat val
                  return $ CmdResult $ PlotMatOut zs
    _ -> return $ Command cmdName ()
   where
     (v, m) = lower expr env
     textResult = CmdResult . TextOut

jitCmd (CmdResult s) _ = return $ CmdResult s
jitCmd (CmdErr e)    _ = return $ CmdErr e

lower :: Expr -> PersistEnv -> (CompileVal, L.Module)
lower expr env = (val, mod)
  where
    compileEnv = runIdentity (traverseJitEnv (Identity . pWordToOperand) env)
    (Right (val, mod)) = lowerLLVM compileEnv expr

pWordToOperand :: PWord -> Operand
pWordToOperand x = case x of
  PScalar _ x   -> litInt (fromIntegral x) -- TODO: don't assume it's an int
  PPtr    _ ptr -> let ptrAsInt = fromIntegral (ptrToWordPtr ptr)
                       ptrConst = C.IntToPtr (C.Int 64 ptrAsInt) intPtrTy
                   in L.ConstantOperand ptrConst

lowerLLVM :: CompileEnv -> Expr -> Except (CompileVal, L.Module)
lowerLLVM env expr = do
  (val, blocks) <- runCompileM env (compileModule expr)
  return (val, makeModule blocks)

showLLVM :: L.Module -> IO String
showLLVM m = withContext $ \c ->
               Mod.withModuleFromAST c m $ \m ->
                 fmap unpack $ Mod.moduleLLVMAssembly m

evalJit :: CompileVal -> L.Module -> IO PersistVal
evalJit v m =
  withContext $ \c ->
    Mod.withModuleFromAST c m $ \m -> do
      jit c $ \ee ->
        EE.withModuleInEngine ee m $ \eee -> do
          fn <- EE.getFunction eee (L.Name "thefun")
          case fn of
            Just fn -> do xPtr <- runJitted fn
                          createPersistVal v xPtr

createPersistVal :: CompileVal -> F.Ptr () -> IO PersistVal
createPersistVal v ptr = do
  ptrRef <- newIORef ptr
  traverse (getNext ptrRef) v

getNext :: IORef (F.Ptr ()) -> Operand -> IO PWord
getNext ref op = do
  ptr <- readIORef ref
  val <- peek (castPtr ptr :: F.Ptr Word64)
  let b = opBaseType op
  writeIORef ref (plusPtr ptr 8)
  return $ if opIsPtr op
                then PPtr    b (wordPtrToPtr (fromIntegral val))
                else PScalar b val

opIsPtr :: Operand -> Bool
opIsPtr op = case op of
  Op.LocalReference  (L.PointerType _ _) _ -> True
  Op.LocalReference  (L.IntegerType _  ) _ -> False
  Op.ConstantOperand (C.Int _ _)           -> False
  Op.ConstantOperand (C.IntToPtr _ _)      -> True

opBaseType :: Operand -> BaseType
opBaseType op = case op of
  Op.LocalReference  (L.PointerType (L.IntegerType _) _) _ -> IntType
  Op.LocalReference  (L.IntegerType _) _ -> IntType
  Op.ConstantOperand (C.Int _ _)         -> IntType
  Op.ConstantOperand (C.IntToPtr _ _)    -> IntType
  _ -> error $ "Can't find type of " ++ show op

makeModule :: [Block] -> L.Module
makeModule blocks = mod
  where
    mod = L.defaultModule { L.moduleName = "test"
                          , L.moduleDefinitions =
                              [ externDecl doubleFun
                              , externDecl mallocFun
                              , externDecl memcpyFun
                              , externDecl hashFun
                              , externDecl randFun
                              , externDecl randIntFun
                              , L.GlobalDefinition fundef] }
    fundef = L.functionDefaults { L.name        = L.Name "thefun"
                                , L.parameters  = ([], False)
                                , L.returnType  = longTy
                                , L.basicBlocks = blocks }

externDecl :: ExternFunSpec -> L.Definition
externDecl (ExternFunSpec fname retTy argTys argNames) =
  L.GlobalDefinition $ L.functionDefaults {
    L.name        = L.Name fname
  , L.parameters  = ([L.Parameter t (L.Name s) []
                     | (t, s) <- zip argTys argNames], False)
  , L.returnType  = retTy
  , L.basicBlocks = []
  }

runCompileM :: CompileEnv -> CompileM a -> Except (a, [Block])
runCompileM env m = do
  (val, CompileState _ blocks [] [] _) <- runStateT (runReaderT m env) initState
  return $ (val, reverse blocks)
  where initState = CompileState 0 [] [] [] (L.Name "main_block")

runJitted :: FunPtr a -> IO (F.Ptr ())
runJitted fn = haskFun (castFunPtr fn :: FunPtr (IO (F.Ptr ())))

jit :: Context -> (EE.MCJIT -> IO a) -> IO a
jit c = EE.withMCJIT c (Just 3) Nothing Nothing Nothing

compileModule :: Expr -> CompileM CompileVal
compileModule expr = do val <- compile expr
                        finalReturn val
                        return val

compile :: Expr -> CompileM CompileVal
compile expr = case expr of
  Lit x -> return (litVal x)
  Var v -> asks $ (! v) . lEnv
  Let p bound body -> do x <- compile bound
                         local (setLEnv $ addBVars (bindPat p x)) (compile body)
  -- For a body -> do (Meta n) <- compileType a
  --                  -- TabType _ bodyTy <- exprType expr
  --                  -- compileFor n bodyTy body
  Get e ie -> do x <- compile e
                 IdxVal _ i <- asks $ (! ie) . lEnv
                 compileGet x i
  RecCon r -> liftM RecVal (traverse compile r)
  -- Unpack _ bound body -> do
  --   ExPackage i x <- compile bound
  --   let updateEnv = setLEnv (addBVar x) . setTEnv (addBVar (Meta i))
  --   local updateEnv (compile body)
  BuiltinApp b ts args -> do ts' <- traverse compileType ts
                             compileBuiltin b ts' args

withEnv :: CompileEnv -> CompileM a -> CompileM a
withEnv env = local (const env)

exprType :: Expr -> CompileM CompileType
exprType expr = undefined -- do { env <- ask; return (exprType env expr) }

-- exprType :: CompileEnv -> Expr -> CompileType
-- exprType (FullEnv lenv tenv) expr = joinType $ getType lenv expr
--   where lenv' = fmap (fmap Meta . typeOf) lenv

typeOf :: CompileVal -> CompileType
typeOf val = undefined -- case val of
  -- ScalarVal b _ -> BaseType b
  -- -- IdxVal n _ -> Meta n
  -- TabVal (Table _ n _ valTy) -> TabType (Meta n) valTy

bindPat :: RecTree a -> CompileVal -> [CompileVal]
bindPat (RecTree r) (RecVal r') = concat $ zipWith bindPat (toList r) (toList r')
bindPat (RecLeaf l) x = [x]

compileType :: Type -> CompileM CompileType
compileType ty = undefined -- do env <- asks tEnv
                    -- return $ instantiateBodyFVs (fmap Just env) ty

compileFor :: NumElems -> CompileType -> Expr -> CompileM CompileVal
compileFor n bodyTy forBody = do
  tab <- newTable bodyTy n
  let body iPtr = do i <- loadCell iPtr
                     let updateEnv = setLEnv $ addBVar (IdxVal n i)
                     bodyVal <- local updateEnv $ compile forBody
                     writeTable tab i bodyVal
  addForILoop n body
  return $ TabVal tab


compileGet :: CompileVal -> Index -> CompileM CompileVal
compileGet (TabVal tab) i = readTable tab i

litVal :: LitVal -> CompileVal
litVal lit = case lit of
  IntLit  x -> ScalarVal IntType  $ L.ConstantOperand $ C.Int 64 (fromIntegral x)
  RealLit x -> ScalarVal RealType $ L.ConstantOperand $ C.Float (L.Double x)

-- --- utilities ---

addLoop :: CompileM Long -> CompileM a -> CompileM a
addLoop cond body = do block <- newBlock  -- TODO: handle zero iters case
                       val <- body
                       c <- cond
                       maybeLoop c block
                       return val

newBlock :: CompileM L.Name
newBlock = do next <- freshName
              finishBlock (L.Br next []) next
              return next

maybeLoop :: Long -> L.Name -> CompileM ()
maybeLoop c loop = do next <- freshName
                      finishBlock (L.CondBr c loop next []) next

addForILoop :: Long -> (CPtr -> CompileM a) -> CompileM a
addForILoop n body = do
  i <- newIntCell 0
  let cond  = loadCell i >>= (`lessThan` n)
      body' = body i <* inc i
  addLoop cond body'
  where inc i = updateCell i $ add (litInt 1)

unpackConsTuple :: Int -> CompileVal -> [CompileVal]
unpackConsTuple 0 _ = []
unpackConsTuple n (RecVal r) = head : unpackConsTuple (n-1) tail
  where [head, tail] = fromPosRecord r

compileBuiltin :: Builtin -> [CompileType] -> [Expr] -> CompileM CompileVal
compileBuiltin Fold ts [f, arg] = error "fold"
compileBuiltin b ts [arg] = do
  arg <- compile arg
  (builtinRule b) ts $ unpackConsTuple (numArgs b) arg

builtinRule :: Builtin -> CompileApp
builtinRule b = case b of
  Add      -> compileBinop (\x y -> L.Add False False x y [])
  Mul      -> compileBinop (\x y -> L.Mul False False x y [])
  Sub      -> compileBinop (\x y -> L.Sub False False x y [])
  Iota     -> compileIota
  Fold     -> compileFold
  Doubleit -> externalMono doubleFun  IntType
  Hash     -> externalMono hashFun    IntType
  Rand     -> externalMono randFun    RealType
  Randint  -> externalMono randIntFun IntType

compileBinApp :: CompileVal -> CompileVal -> (CompileVal -> CompileM CompileVal)
compileBinApp f x y = undefined --do f' <- compileApp f x
--                         compileApp f' y

compileFold :: [CompileType] -> [CompileVal] -> CompileM CompileVal
compileFold _ [fVal, init, TabVal tab@(Table ptr n sizes valTy)] = undefined --do
  -- mutVal <- newGenCell init
  -- let body iPtr = do i <- loadCell iPtr
  --                    next <-readTable tab i
  --                    updateGenCell mutVal (compileBinApp fVal next)
  -- addForILoop n body
  -- loadGenCell mutVal

-- TODO: add var decls
finalReturn :: CompileVal -> CompileM ()
finalReturn val = do
  let components = toList val
      numBytes = 8 * length components
  voidPtr <- evalInstr charPtrTy (externCall mallocFun [litInt numBytes])
  outPtr <- evalInstr intPtrTy $ L.BitCast voidPtr intPtrTy []
  sequence $ zipWith (writeComponent outPtr) components [0..]
  finishBlock (L.Ret (Just outPtr) []) (L.Name "")

writeComponent :: Operand -> Operand -> Int -> CompileM ()
writeComponent ptr x i = do
  ptr' <- evalInstr intPtrTy $ L.GetElementPtr False ptr [litInt i] []
  writeCell (Ptr ptr') x

appendInstr :: Instr -> CompileM ()
appendInstr instr = modify updateState
  where updateState state = state {curInstrs = instr : curInstrs state}

freshName :: CompileM L.Name
freshName = do i <- gets nameCounter
               modify (\state -> state {nameCounter = i + 1})
               return $ L.UnName (fromIntegral i)

finishBlock :: L.Terminator -> L.Name -> CompileM ()
finishBlock term newName = do
  CompileState count blocks instrs decls oldName <- get
  let newBlock = L.BasicBlock oldName (reverse instrs) (L.Do term)
  put $ CompileState count (newBlock:blocks) [] decls newName

evalInstr :: L.Type -> L.Instruction -> CompileM Operand
evalInstr ty instr = do
  x <- freshName
  appendInstr $ x L.:= instr
  return $ L.LocalReference ty x

litInt :: Int -> Long
litInt x = L.ConstantOperand $ C.Int 64 (fromIntegral x)

add :: Long -> Long -> CompileM Long
add x y = evalInstr longTy $ L.Add False False x y []

sumLongs :: [Long] -> CompileM Long
sumLongs xs = foldM add (litInt 0) xs

mul :: Long -> Long -> CompileM Long
mul x y = evalInstr longTy $ L.Mul False False x y []

newIntCell :: Int -> CompileM CPtr
newIntCell x = do
  ptr <- liftM Ptr $ evalInstr intPtrTy $
           L.Alloca longTy Nothing 0 [] -- TODO: add to top block!
  writeCell ptr (litInt x)
  return ptr

loadCell :: CPtr -> CompileM Long
loadCell (Ptr ptr) =
  evalInstr longTy $ L.Load False ptr Nothing 0 []

writeCell :: CPtr -> Long -> CompileM ()
writeCell (Ptr ptr) x =
  appendInstr $ L.Do $ L.Store False ptr x Nothing 0 []

updateCell :: CPtr -> (Long -> CompileM Long) -> CompileM ()
updateCell ptr f = loadCell ptr >>= f >>= writeCell ptr


newGenCell :: CompileVal -> CompileM CPtr
newGenCell (ScalarVal IntType x)  = do
  ptr <- liftM Ptr $ evalInstr intPtrTy $
           L.Alloca longTy Nothing 0 [] -- TODO: add to top block!
  writeGenCell ptr (ScalarVal IntType x)
  return ptr

loadGenCell :: CPtr -> CompileM CompileVal
loadGenCell (Ptr ptr) =
  liftM (ScalarVal IntType) $ evalInstr longTy $ L.Load False ptr Nothing 0 []

writeGenCell :: CPtr -> CompileVal -> CompileM ()
writeGenCell (Ptr ptr) (ScalarVal IntType x) =
  appendInstr $ L.Do $ L.Store False ptr x Nothing 0 []

updateGenCell :: CPtr -> (CompileVal -> CompileM CompileVal) -> CompileM ()
updateGenCell ptr f = loadGenCell ptr >>= f >>= writeGenCell ptr


newTable :: CompileType -> NumElems -> CompileM CTable
newTable ty n = do
  let (scalarSize, scalarTy) = baseTypeInfo ty
  numScalars <- getNumScalars ty
  elemSize <- mul (litInt scalarSize) numScalars
  (numBytes) <- mul n elemSize
  voidPtr <- evalInstr charPtrTy (externCall mallocFun [numBytes])
  ptr <- evalInstr (L.ptr scalarTy) $ L.BitCast voidPtr (L.ptr scalarTy) []
  return $ Table (Ptr ptr) n (ConstSize numScalars) ty

baseTypeInfo :: CompileType -> (Int, L.Type)
baseTypeInfo ty = undefined -- case ty of
  -- BaseType b -> case b of IntType  -> (8, longTy)
  --                         RealType -> (8, realTy)
  -- TabType _ valTy -> baseTypeInfo valTy

getNumScalars :: CompileType -> CompileM Long
getNumScalars ty = undefined -- case ty of
  -- BaseType _ -> return $ litInt 1
  -- TabType (Meta i) valTy -> do n <- getNumScalars valTy
  --                              mul i n
  -- RecType r -> mapM getNumScalars (toList r) >>= sumLongs
  -- _ -> error $ show ty

readTable :: CTable -> Index -> CompileM CompileVal
readTable tab@(Table _ _ _ valTy) idx = undefined --do
  -- ptr <- arrayPtr tab idx
  -- case valTy of
  --   BaseType IntType -> do ans <- loadCell ptr
  --                          return $ ScalarVal IntType ans
  --   TabType (Meta n) valTy' -> do
  --     numScalars <- getNumScalars valTy'
  --     return $ TabVal (Table ptr n (ConstSize numScalars) valTy')

writeTable :: CTable -> Index -> CompileVal -> CompileM ()
writeTable tab idx val = do
  (Ptr dest) <- arrayPtr tab idx
  case val of
    ScalarVal IntType val' -> writeCell (Ptr dest) (val')
    TabVal (Table (Ptr src) n (ConstSize numScalars) ty) -> do
      let (scalarSize, _) = baseTypeInfo ty
      elemSize <- mul (litInt scalarSize) numScalars
      numBytes <- mul n elemSize
      appendInstr $ L.Do (externCall memcpyFun [dest, src, numBytes])

arrayPtr :: CTable -> Index -> CompileM CPtr
arrayPtr (Table (Ptr ptr) _ (ConstSize size) _) idx = do
  (offset) <- mul size idx
  liftM Ptr $ evalInstr charPtrTy $ L.GetElementPtr False ptr [offset] []

lessThan :: Long -> Long -> CompileM Long
lessThan (x) (y) = evalInstr longTy $ L.ICmp L.SLT x y []

charPtrTy = L.ptr (L.IntegerType 8)
intPtrTy = L.ptr longTy
longTy = L.IntegerType 64
realTy = L.FloatingPointType L.DoubleFP

funTy :: L.Type -> [L.Type] -> L.Type
funTy retTy argTys = L.ptr $ L.FunctionType retTy argTys False

externCall :: ExternFunSpec -> [L.Operand] -> L.Instruction
externCall (ExternFunSpec fname retTy argTys _) args =
  L.Call Nothing L.C [] fun args' [] []
  where fun = Right $ L.ConstantOperand $ C.GlobalReference
                         (funTy retTy argTys) (L.Name fname)
        args' = [(x ,[]) | x <- args]

mallocFun = ExternFunSpec "malloc_cod" charPtrTy [longTy] ["nbytes"]
memcpyFun = ExternFunSpec "memcpy_cod" L.VoidType
               [charPtrTy, charPtrTy, longTy]
               ["dest", "src", "nbytes"]

-- --- builtins ---

externalMono :: ExternFunSpec -> BaseType -> CompileApp
externalMono f@(ExternFunSpec name retTy _ _) baseTy [] args =
  liftM (ScalarVal baseTy) $ evalInstr retTy (externCall f args')
  where args' = map asOp args
        asOp :: CompileVal -> L.Operand
        asOp (ScalarVal _ op) = op

compileDoubleit :: CompileApp
compileDoubleit [] [ScalarVal IntType x] =
  liftM (ScalarVal IntType) $ evalInstr longTy (externCall doubleFun [x])

doubleFun  = ExternFunSpec "doubleit"      longTy [longTy] ["x"]
randFun    = ExternFunSpec "randunif"      realTy [longTy] ["keypair"]
randIntFun = ExternFunSpec "randint"       longTy [longTy, longTy] ["keypair", "nmax"]
hashFun    = ExternFunSpec "threefry_2x32" longTy [longTy, longTy] ["keypair", "count"]

compileIota :: CompileApp
compileIota [] [ScalarVal b n] = undefined -- do
  -- tab@(Table ptr _ _ _) <- newTable (BaseType IntType) n
  -- let body iPtr = do (i) <- loadCell iPtr
  --                    writeTable tab i (ScalarVal IntType i)
  -- addForILoop n body
  -- return $ ExPackage n (TabVal tab)

compileBinop :: (Operand -> Operand -> L.Instruction) -> CompileApp
compileBinop makeInstr = compile
  where
    compile :: CompileApp
    compile [] [ScalarVal _ x, ScalarVal _ y] = liftM (ScalarVal IntType) $
        evalInstr longTy (makeInstr x y)

-- --- printing ---

data RectTable a = RectTable [Int] [a]  deriving (Show)
data PrintSpec = PrintSpec { manualAlign :: Bool }
defaultPrintSpec = PrintSpec True

printPersistVal :: PersistVal -> IO String
printPersistVal (ScalarVal b x) = case x of
  PScalar _ x   -> return $ show x
printPersistVal (TabVal tab) = do
  rTab <- makeRectTable tab
  return $ showRectTable rTab

makeRectTable :: Table PWord -> IO (RectTable Int64)
makeRectTable (Table (Ptr (PPtr IntType voidPtr))
              (PScalar IntType numElems) elemSize valTy) = do
  vect <- mapM (peekElemOff ptr) [0.. (product shape - 1)]
  return $ RectTable shape vect
  where shape = fromIntegral numElems : shapeOf valTy
        ptr = castPtr voidPtr :: F.Ptr Int64

shapeOf :: PersistType -> [Int]
shapeOf ty = undefined -- case ty of
  -- TabType (Meta (PScalar IntType size)) val -> fromIntegral size : shapeOf val
  -- BaseType _ -> []

idxProduct :: [Int] -> [[Int]]
idxProduct [] = [[]]
idxProduct (dim:shape) = [i:idxs | i <- [0 .. dim-1], idxs <- idxProduct shape]

showRectTable :: Show a => RectTable a -> String
showRectTable (RectTable shape vect) = alignCells rows
  where rows = [ (map show idxs) ++ [show val]
               | (idxs, val) <- zip (idxProduct shape) vect]

alignCells :: [[String]] -> String
alignCells rows = unlines $ if manualAlign defaultPrintSpec
  then let colLengths = map maxLength (transpose rows)
           rows' = map padRow rows
           padRow = zipWith (padLeft ' ') colLengths
       in map (intercalate " ") rows'
  else map (intercalate "\t") rows

maxLength :: [String] -> Int
maxLength = foldr (\x y -> max (length x) y) 0

instance Functor JitVal where
  fmap = fmapDefault

instance Foldable JitVal where
  foldMap = foldMapDefault

instance Traversable JitVal where
  traverse f val = case val of
    ScalarVal ty x -> liftA (ScalarVal ty) (f x)
    IdxVal size idx -> liftA2 IdxVal (f size) (f idx)
    -- TabVal (Table (Ptr p) n (ConstSize size) valTy) -> liftA TabVal $
    --     (Table <$> liftA Ptr (f p)
    --            <*> f n
    --            <*> liftA ConstSize (f size)
    --            <*> traverse f valTy )
    RecVal r -> liftA RecVal $ traverse (traverse f) r
    ExPackage size val -> liftA2 ExPackage (f size) (traverse f val)

traverseJitEnv :: Applicative f => (a -> f b) -> JitEnv a -> f (JitEnv b)
traverseJitEnv f env = undefined -- liftA2 FullEnv (traverse (traverse f) $ lEnv env)
                                      -- (traverse (traverse f) $ tEnv env)

makePlot :: PersistVal -> IO ([Float], [Float])
makePlot (TabVal (Table (Ptr (PPtr IntType voidPtr)) (PScalar IntType n) _ _ )) = do
  let idxs  = [0.. (fromIntegral n - 1)]
  vect <- mapM (peekElemOff ptr) idxs
  return (map fromIntegral idxs,
          map fromIntegral vect)
  where ptr = castPtr voidPtr :: F.Ptr Int64

makePlotMat :: PersistVal -> IO [[Float]]
makePlotMat (TabVal (Table (Ptr (PPtr IntType voidPtr))
                         (PScalar IntType numRows) _ valTy)) = do
  let [numCols] = shapeOf valTy
  vect <- mapM (peekElemOff ptr) [0.. (numRows' * numCols - 1)]
  return $ reshape numRows' numCols $ (map fromIntegral vect :: [Float])
  where shape = numRows' : shapeOf valTy
        ptr = castPtr voidPtr :: F.Ptr Int64
        numRows' = fromIntegral numRows :: Int

reshape :: Int -> Int -> [a] -> [[a]]
reshape 0 _ [] = []
reshape r c xs = let (row, rest) = splitAt c xs
                 in row : reshape (r-1) c rest