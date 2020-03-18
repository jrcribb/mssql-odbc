{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE DeriveGeneric              #-}

module Database.MSSQL.Internal
  ( module Database.MSSQL.Internal.SQLError
  , module Database.MSSQL.Internal.ConnectAttribute
  , module Database.MSSQL.Internal
  ) where

import Database.MSSQL.Internal.ConnectAttribute
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as BSB
import qualified Language.C.Inline as C
import Foreign.Storable
import Foreign.C
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Marshal.Alloc (alloca)
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.Coerce
import Database.MSSQL.Internal.Ctx
import Database.MSSQL.Internal.SQLError
import Data.Text.Foreign as T
import qualified Data.Text as T
-- import Text.Read
import Data.IORef
import Data.Word
import Data.Int
import GHC.Generics
import Control.Monad.Trans.Reader (ReaderT (..))
import Control.Monad.IO.Class
import Data.Time
import Data.UUID.Types (UUID)
import Database.MSSQL.Internal.SQLTypes
import Data.Functor.Identity
import Control.Monad
import Data.String
import qualified Data.HashMap.Strict as HM
#if __GLASGOW_HASKELL__ < 802
import Data.Semigroup
#endif
import Data.Functor.Compose
import Control.Applicative hiding ((<**>))
import Data.Scientific
import Data.Typeable
-- import qualified Data.Text.Lazy.Builder as LTB
-- import qualified Data.Text.Lazy as LT
import GHC.TypeLits
-- import qualified Data.Text.Lazy.Encoding as LTE
-- import qualified Data.Text.Encoding as TE
import Data.Char (isAscii)
import Control.Exception (Exception, throwIO, bracket, onException, finally)
-- import Foreign.Marshal.Utils (fillBytes)
import qualified Foreign.C.String as F


data ConnectParams = ConnectParams
                     T.Text
                     T.Text
                     T.Text
                     T.Text
                     Word16
                     OdbcDriver
                     Properties
                     deriving Show

data OdbcDriver = OdbcSQLServer Word8
                | OtherOdbcDriver T.Text
                deriving Show

odbcSQLServer17 :: OdbcDriver
odbcSQLServer17 = OdbcSQLServer 17

odbcSQLServer12 :: OdbcDriver
odbcSQLServer12 = OdbcSQLServer 12

ppOdbcDriver :: OdbcDriver -> T.Text
ppOdbcDriver dv = case dv of
  OdbcSQLServer v   -> "Driver={ODBC Driver " <> T.pack (show v) <> " for SQL Server};"
  OtherOdbcDriver t -> "Driver=" <> t <> ";"

ppConnectionString :: ConnectionString -> T.Text
ppConnectionString (ConnectionString' (Left str)) = str
ppConnectionString (ConnectionString' (Right (ConnectParams db ser pass usr pt dv cp))) =
  let ppDriver    = ppOdbcDriver dv
      ppServer    = ser
      ppDb        = db
      ppPass      = pass
      ppUser      = usr
      ppPort      = tshow pt
      
  in ppDriver <>
     "Server=" <> ppServer <> "," <> ppPort <> ";" <>
     "Database=" <> ppDb <> ";" <>
     "UID="<> ppUser <>";PWD=" <> ppPass <>";" <>
     ppProps cp

  where tshow = T.pack . show
        ppProps = HM.foldlWithKey' (\k v ac -> k <> "=" <> v <> ";" <> ac) "" 


newtype ConnectionString = ConnectionString' { getConString :: Either T.Text ConnectParams }
                         deriving (Show)

type Properties = HM.HashMap T.Text T.Text

defProperties :: Properties
defProperties = HM.empty

pattern ConnectionString :: T.Text -> T.Text -> Word16 -> T.Text -> T.Text -> OdbcDriver -> Properties -> ConnectionString
pattern ConnectionString { database, server, port, user, password, odbcDriver, connectProperties } =
  ConnectionString' (Right (ConnectParams database server password user port odbcDriver connectProperties))
  
instance IsString ConnectionString where
  fromString = ConnectionString' . Left . T.pack

data ConnectInfo = ConnectInfo
  { connectionString :: ConnectionString
  , attrBefore :: [ConnectAttr 'ConnectBefore]
  , attrAfter  :: [ConnectAttr 'ConnectAfter]
  }


data SQLHENV
data SQLHDBC
data SQLHSTMT
data SQLHANDLE

newtype ColPos = ColPos (IORef CUShort)

data HSTMT a = HSTMT
  { getHSTMT :: Ptr SQLHSTMT
  , colPos   :: ColPos
  , numResultCols :: CShort
  } deriving Functor

C.context $ mssqlCtx
  [ ("SQLWCHAR", [t|CWchar|])
  , ("SQLCHAR", [t|CChar|]) 
  , ("SQLHANDLE", [t|Ptr SQLHANDLE|])
  , ("SQLHENV" , [t|Ptr SQLHENV|])
  , ("SQLHDBC" , [t|Ptr SQLHDBC|])
  , ("SQLHSTMT" , [t|Ptr SQLHSTMT|])
  , ("SQLSMALLINT", [t|CShort|])
  , ("SQLUSMALLINT", [t|CUShort|])
  , ("SQLREAL", [t|CFloat|])
  , ("SQLFLOAT", [t|CDouble|])
  , ("SQLDOUBLE", [t|CDouble|])
  , ("SQLUINTEGER", [t|CULong|])
  , ("SQLINTEGER", [t|CLong|])
  , ("SQLLEN", [t|CLong|])
  , ("SQLULEN", [t|CULong|])
  , ("SQL_DATE_STRUCT", [t|CDate|])
  , ("SQL_TIME_STRUCT", [t|CTimeOfDay|])
  , ("SQL_SS_TIME2_STRUCT", [t|CTimeOfDay|])
  , ("SQL_TIMESTAMP_STRUCT", [t|CLocalTime|])
  , ("SQL_SS_TIMESTAMPOFFSET_STRUCT", [t|CZonedTime|])
  , ("SQLGUID", [t|UUID|])
  ]

C.verbatim "#define UNICODE"

#ifdef mingw32_HOST_OS
C.include "<windows.h>"
#endif
C.include "<stdio.h>"
C.include "<stdlib.h>"
C.include "<sqlext.h>"
C.include "<sqltypes.h>"
C.include "<sqlucode.h>"
C.include "<ss.h>"

connectInfo :: ConnectionString -> ConnectInfo
connectInfo conStr = ConnectInfo
  { connectionString = conStr
  , attrBefore = mempty
  , attrAfter = mempty
  }

data Connection = Connection
  { _henv :: Ptr SQLHENV
  , _hdbc :: Ptr SQLHDBC
  } deriving (Show)

data SQLNumResultColsException = SQLNumResultColsException { expected :: CShort, actual :: CShort }
                              deriving (Generic)

instance Exception SQLNumResultColsException

instance Show SQLNumResultColsException where
  show (SQLNumResultColsException e a) =
    "Mismatch between expected column count and actual query column count. Expected column count is " <>
    show e <> ", but actual query column count is " <> show a

data SQLException = SQLException {getSQLErrors :: SQLErrors }
                  deriving (Show, Generic)

instance Exception SQLException

throwSQLException :: (MonadIO m) => SQLErrors -> m a
throwSQLException = liftIO . throwIO . SQLException

connect :: ConnectInfo -> IO Connection
connect connInfo = do
  alloca $ \(henvp :: Ptr (Ptr SQLHENV)) -> do
    alloca $ \(hdbcp :: Ptr (Ptr SQLHDBC)) -> do
      doConnect henvp hdbcp
  where
    setAttrs hdbcp hdbc = go
       where go connAttr = do
               let 
               -- TODO: Note void* next to SQLPOINTER, antiquoter gave a parse error.
               (attr, vptr, len) <- connectAttrPtr connAttr
               ret <- ResIndicator <$> [C.block| int {
                    SQLRETURN ret = 0;
                    SQLHDBC* hdbcp = $(SQLHDBC* hdbcp);
                    SQLINTEGER attr = $(SQLINTEGER attr);
                    SQLPOINTER vptr = $fptr-ptr:(void* vptr);
                    SQLINTEGER len = $(SQLINTEGER len);      
                    ret = SQLSetConnectAttr(*hdbcp, attr, vptr, len);
                    return ret;
                    }|]        
               when (not (isSuccessful ret)) $
                 getErrors ret (SQLDBCRef hdbc) >>= throwSQLException
    setAttrsBeforeConnect :: Ptr (Ptr SQLHDBC) -> Ptr SQLHDBC -> ConnectAttr 'ConnectBefore -> IO ()
    setAttrsBeforeConnect = setAttrs

    setAttrsAfterConnect :: Ptr (Ptr SQLHDBC) -> Ptr SQLHDBC -> ConnectAttr 'ConnectAfter -> IO ()
    setAttrsAfterConnect  = setAttrs

    doConnect henvp hdbcp = do
      (ctxt, i16) <- asForeignPtr $
        ppConnectionString (connectionString connInfo)
      let ctxtLen = fromIntegral i16 :: C.CInt
          
      ret <- ResIndicator <$> [C.block| int {
        SQLRETURN ret = 0;
        SQLHENV* henvp = $(SQLHENV* henvp);
        SQLHDBC* hdbcp = $(SQLHDBC* hdbcp);
      
        ret = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, henvp);
        if (!SQL_SUCCEEDED(ret)) return ret;

        ret = SQLSetEnvAttr(*henvp, SQL_ATTR_ODBC_VERSION, (void*)SQL_OV_ODBC3, 0);
        if (!SQL_SUCCEEDED(ret)) return ret;

        ret = SQLAllocHandle(SQL_HANDLE_DBC, *henvp, hdbcp);
        if (!SQL_SUCCEEDED(ret)) return ret;

        return ret;
        }|]

      henv <- peek henvp
      hdbc <- peek hdbcp

      when (not (isSuccessful ret)) $
        getErrors ret (SQLDBCRef hdbc) >>= throwSQLException
      mapM_ (setAttrsBeforeConnect hdbcp hdbc) (attrBefore connInfo)

      ret' <- ResIndicator <$> [C.block| int {
        SQLRETURN ret = 0;
        SQLHENV* henvp = $(SQLHENV* henvp);
        SQLHDBC* hdbcp = $(SQLHDBC* hdbcp);
      
        SQLWCHAR* cstr = $fptr-ptr:(SQLWCHAR * ctxt);
        ret = SQLDriverConnectW(*hdbcp, 0, cstr, (SQLSMALLINT)$(int ctxtLen), 0, 0, 0, SQL_DRIVER_NOPROMPT);

        return ret;
        }|]

      mapM_ (setAttrsAfterConnect hdbcp hdbc) (attrAfter connInfo)
      case isSuccessful ret' of
        False -> getErrors ret' (SQLDBCRef hdbc) >>= throwSQLException
        True -> pure $ Connection { _henv = henv, _hdbc = hdbc }


      
disconnect :: Connection -> IO ()
disconnect con = do
  ret <- ResIndicator <$> [C.block| int {
    SQLRETURN ret = 0;
    SQLHENV henv = $(SQLHENV henv);
    SQLHDBC hdbc = $(SQLHDBC hdbc);

    if (hdbc != SQL_NULL_HDBC) {
      ret = SQLDisconnect(hdbc);
      if (!SQL_SUCCEEDED(ret)) return ret;
      
      ret = SQLFreeHandle(SQL_HANDLE_DBC, hdbc);
      if (!SQL_SUCCEEDED(ret)) return ret;
    }

    if (henv != SQL_NULL_HENV)
    {
      ret = SQLFreeHandle(SQL_HANDLE_ENV, henv);
      if (!SQL_SUCCEEDED(ret)) return ret;
    }
    return ret;

  }|]

  case isSuccessful ret of
    True -> pure ()
    False -> do
      dbErrs <- getErrors ret (SQLDBCRef hdbc)
      envErrs <- getErrors ret (SQLENVRef henv)
      throwSQLException (dbErrs <> envErrs)
  where
    hdbc = _hdbc con
    henv = _henv con

data HandleRef
  = SQLENVRef (Ptr SQLHENV)
  | SQLDBCRef (Ptr SQLHDBC)
  | SQLSTMTRef (Ptr SQLHSTMT)
  
getMessages :: HandleRef -> IO (Either SQLError [(T.Text, T.Text)])
getMessages handleRef = do
  msgsRef <- newIORef []
  appendMessage <- appendMessageM msgsRef
  let
    (HandleType handleType, handle, handleName) = case handleRef of
      SQLENVRef h -> (SQL_HANDLE_ENV, castPtr h, "ENV")
      SQLDBCRef h -> (SQL_HANDLE_DBC, castPtr h, "DATABASE")
      SQLSTMTRef h -> (SQL_HANDLE_STMT, castPtr h, "STATEMENT")
  ret <- [C.block| int {
             SQLRETURN ret = 0;
             SQLSMALLINT i = 0;
             SQLWCHAR eState [6]; 
             SQLWCHAR eMSG [SQL_MAX_MESSAGE_LENGTH];
             SQLSMALLINT eMSGLen;
             SQLHANDLE handle = $(SQLHANDLE handle);
             printf("%d", SQL_MAX_MESSAGE_LENGTH);
             void (*appendMessage)(SQLWCHAR*, int, SQLWCHAR*, int) = $(void (*appendMessage)(SQLWCHAR*, int, SQLWCHAR*, int));
             do {
               ret = SQLGetDiagRecW((SQLSMALLINT)$(int handleType), handle, ++i, eState, NULL, eMSG, SQL_MAX_MESSAGE_LENGTH, &eMSGLen);
               if (SQL_SUCCEEDED(ret)) {
                  appendMessage(eState, 5, eMSG, eMSGLen);
               }
             } while( ret == SQL_SUCCESS );

             if (!SQL_SUCCEEDED(ret)) return ret;
             
             
             return 0;
         }|]
  case ret of
    0    -> Right <$> readIORef msgsRef
    100  -> Right <$> readIORef msgsRef
    -2 -> pure $ Left $ SQLError
            { sqlState = ""
            , sqlMessage = "Invalid " <> handleName <> " handle"
            , sqlReturn  = -2
            }
    e  -> pure $ Left $ SQLError
            { sqlState = ""
            , sqlMessage = "UNKNOWN ERROR"
            , sqlReturn  = fromIntegral e
            }
  where
    appendMessageM :: IORef [(T.Text, T.Text)] -> IO (FunPtr (Ptr CWchar -> CInt -> Ptr CWchar -> CInt -> IO ()))
    appendMessageM msgsRef = $(C.mkFunPtr [t| Ptr CWchar
                                 -> C.CInt
                                 -> Ptr CWchar
                                 -> C.CInt
                                 -> IO ()
                                |]) $ \state _stateLen msg msgLen -> do
      msgText <- fromPtr (coerce msg) (fromIntegral msgLen)
      stateText <- fromPtr (coerce state) 5
      modifyIORef' msgsRef (\ms -> ms ++ [(msgText, stateText)])
      pure ()

getErrors :: ResIndicator -> HandleRef -> IO SQLErrors
getErrors res handleRef = do
  putStrLn $  "in get errors: " ++ show res
  msgE <- getMessages handleRef
  pure $ SQLErrors $ case msgE of
    Left es -> [es]
    Right msgs -> fmap (\(msg, st) -> SQLError
                                      { sqlState = st
                                      , sqlMessage = msg
                                      , sqlReturn = coerce res
                                      }) msgs

sqldirect :: Connection -> Ptr SQLHSTMT -> T.Text -> IO CShort
sqldirect _con hstmt sql = do
  (queryWStr, queryLen) <- fmap (fmap fromIntegral) $ asForeignPtr $ sql
  numResultColsFP :: ForeignPtr CShort <- mallocForeignPtr

  ret <- ResIndicator <$> [C.block| int {
    SQLRETURN ret = 0;
    SQLHSTMT hstmt = $(SQLHSTMT hstmt);
    SQLSMALLINT* numColumnPtr = $fptr-ptr:(SQLSMALLINT* numResultColsFP);

    ret = SQLExecDirectW(hstmt, $fptr-ptr:(SQLWCHAR* queryWStr), $(int queryLen));
    if (!SQL_SUCCEEDED(ret)) return ret;

    ret = SQLNumResultCols(hstmt, numColumnPtr);

    return ret;
    }|]
  
  case isSuccessful ret of
    False -> getErrors ret (SQLSTMTRef hstmt) >>= throwSQLException
    True -> do
      colCount <- peekFP numResultColsFP
      pure colCount
        
allocHSTMT :: Connection -> IO (HSTMT a)
allocHSTMT con = do
  alloca $ \(hstmtp :: Ptr (Ptr SQLHSTMT)) -> do
    ret <- ResIndicator <$> [C.block| SQLRETURN {
      SQLRETURN ret = 0;
      SQLHSTMT* hstmtp = $(SQLHSTMT* hstmtp);
      SQLHDBC hdbc = $(SQLHDBC hdbc);
      ret = SQLAllocHandle(SQL_HANDLE_STMT, hdbc, hstmtp);
      return ret;
    }|]

    case isSuccessful ret of
      False -> getErrors ret (SQLDBCRef hdbc) >>= throwSQLException
      True -> do
        hstmt <- peek hstmtp
        cpos <- initColPos
        pure $ HSTMT hstmt cpos 0
  where
    hdbc = _hdbc con


releaseHSTMT :: HSTMT a -> IO ()
releaseHSTMT stmt = do
  ret <- ResIndicator <$> [C.block| SQLRETURN {
      SQLRETURN ret = 0;
      SQLHSTMT hstmt =  $(SQLHSTMT hstmt);
      if (hstmt != SQL_NULL_HSTMT) {
        ret = SQLFreeHandle(SQL_HANDLE_STMT, hstmt);
      }
      return ret;
  }|]

  case isSuccessful ret of
    True -> pure ()
    False -> getErrors ret (SQLSTMTRef hstmt) >>= throwSQLException
  where
    hstmt = getHSTMT stmt

withHSTMT :: Connection -> (HSTMT a -> IO a) -> IO a
withHSTMT con act = do
  bracket (allocHSTMT con)
          (releaseHSTMT)
          act

sqlFetch :: HSTMT a -> IO CInt
sqlFetch stmt = do
  [C.block| int {
      SQLRETURN ret = 0;
      SQLHSTMT hstmt = $(SQLHSTMT hstmt);

      ret = SQLFetch(hstmt);

      return ret;
  }|]
  where
    hstmt = getHSTMT stmt

type InfoType = Int
-- getInfo return either string or ulong based on infotype. TODO: needs to handle that
sqlGetInfo :: Connection -> InfoType -> IO (Either SQLErrors T.Text)
sqlGetInfo con 0  = do
  (infoFP :: ForeignPtr Word16) <- mallocForeignPtrBytes (16 * 1024)
  (bufferSizeOut :: ForeignPtr Int) <- mallocForeignPtr
  ret <- ResIndicator <$> [C.block| SQLRETURN {
      SQLRETURN ret = 0;
      SQLHDBC hdbc = $(SQLHDBC hdbc);
      ret = SQLGetInfo(hdbc, SQL_DATABASE_NAME, $fptr-ptr:(SQLWCHAR* infoFP), (SQLSMALLINT)(16 * 1024), $fptr-ptr:(SQLSMALLINT * bufferSizeOut));
      return ret;
  }|]

  case isSuccessful ret of
    False -> Left <$> getErrors ret (SQLDBCRef hdbc)
    True -> do
      bufferSize <- withForeignPtr bufferSizeOut peek
      info <- withForeignPtr infoFP $ \infoP -> fromPtr infoP (round ((fromIntegral bufferSize :: Double)/2))
      pure $ Right info
  where
    hdbc = _hdbc con
sqlGetInfo con _  = do
  (infoFP :: ForeignPtr CULong) <- mallocForeignPtr
  withForeignPtr infoFP $ \infoP -> do
    ret <- ResIndicator <$> [C.block| SQLRETURN {
             SQLRETURN ret = 0;
             SQLHDBC hdbc = $(SQLHDBC hdbc);
             ret = SQLGetInfo(hdbc, SQL_MAX_CONCURRENT_ACTIVITIES, $(SQLUINTEGER* infoP), (SQLSMALLINT)(sizeof(SQLUINTEGER)), NULL);
             return ret;
           }|]

    case isSuccessful ret of
      False -> Left <$> getErrors ret (SQLDBCRef hdbc)
      True -> do
        (Right . T.pack . show) <$> peek infoP
  where
    hdbc = _hdbc con

withTransaction :: Connection -> (Connection -> IO a) -> IO a
withTransaction conn@(Connection { _hdbc = hdbcp }) f = do
  sqlSetAutoCommitOn hdbcp
  go `onException` sqlRollback hdbcp
     `finally` sqlSetAutoCommitOff hdbcp

  where go = do
          a <- f conn
          sqlCommit hdbcp
          pure a
  
sqlSetAutoCommitOn :: Ptr SQLHDBC -> IO ()
sqlSetAutoCommitOn hdbcp = do
  ret <- ResIndicator <$> [C.block| int {
      SQLRETURN ret = 0;
      SQLHDBC hdbcp = $(SQLHDBC hdbcp);
      ret = SQLSetConnectAttr(hdbcp, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER)SQL_AUTOCOMMIT_ON, 0);
      return ret;
      } |]
  case isSuccessful ret of
    False -> do
      getErrors ret (SQLDBCRef hdbcp) >>= throwSQLException
    True -> pure ()

sqlSetAutoCommitOff :: Ptr SQLHDBC -> IO ()
sqlSetAutoCommitOff hdbcp = do
  ret <- ResIndicator <$> [C.block| int {
      SQLRETURN ret = 0;
      SQLHDBC hdbcp = $(SQLHDBC hdbcp);
      ret = SQLSetConnectAttr(hdbcp, SQL_ATTR_AUTOCOMMIT, (SQLPOINTER)SQL_AUTOCOMMIT_OFF, 0);
      return ret;
      } |]

  case isSuccessful ret of
    False -> do
      getErrors ret (SQLDBCRef hdbcp) >>= throwSQLException
    True -> pure ()

sqlCommit :: Ptr SQLHDBC -> IO ()
sqlCommit hdbcp = do
  ret <- ResIndicator <$> [C.block| int {
      SQLRETURN ret = 0;
      SQLHDBC hdbcp = $(SQLHDBC hdbcp);
      ret = SQLEndTran(SQL_HANDLE_DBC, hdbcp, SQL_COMMIT);
      return ret;
      } |]

  case isSuccessful ret of
    False -> do
      getErrors ret (SQLDBCRef hdbcp) >>= throwSQLException
    True -> pure ()

sqlRollback :: Ptr SQLHDBC -> IO ()
sqlRollback hdbcp = do
  ret <- ResIndicator <$> [C.block| int {
      SQLRETURN ret = 0;
      SQLHDBC hdbcp = $(SQLHDBC hdbcp);
      ret = SQLEndTran(SQL_HANDLE_DBC, hdbcp, SQL_ROLLBACK);
      return ret;
      } |]

  case isSuccessful ret of
    False -> do
      getErrors ret (SQLDBCRef hdbcp) >>= throwSQLException
    True -> pure ()

data ColDescriptor = ColDescriptor
  { colName         :: T.Text
  , colDataType     :: SQLType
  , colSize         :: Word
  , colDecimalDigit :: Int
  , colIsNullable   :: Maybe Bool
  , colPosition     :: CUShort
  } deriving (Show, Eq)

-- NOTE: use SQLGetTypeInfo to get signed info
sqlDescribeCol :: Ptr SQLHSTMT -> CUShort -> IO ColDescriptor
sqlDescribeCol hstmt colPos' = do
  (nameLengthFP :: ForeignPtr CShort) <- mallocForeignPtr
  (dataTypeFP :: ForeignPtr CShort) <- mallocForeignPtr
  (decimalDigitsFP :: ForeignPtr CShort) <- mallocForeignPtr
  (nullableFP :: ForeignPtr CShort) <- mallocForeignPtr
  (colSizeFP :: ForeignPtr CULong) <- mallocForeignPtr
  (tabNameFP :: ForeignPtr Word16) <- mallocForeignPtrBytes (16 * 128)
  withForeignPtr nameLengthFP $ \nameLengthP -> do
    withForeignPtr dataTypeFP $ \dataTypeP -> do
       withForeignPtr decimalDigitsFP $ \decimalDigitsP -> do
         withForeignPtr nullableFP $ \nullableP -> do
           withForeignPtr colSizeFP $ \colSizeP -> do
             withForeignPtr (castForeignPtr tabNameFP) $ \tabNameP -> do
               ret <- ResIndicator <$> [C.block| SQLRETURN {
                          SQLRETURN ret = 0;
                          SQLHSTMT hstmt = $(SQLHSTMT hstmt);
                          SQLSMALLINT* nameLengthP = $(SQLSMALLINT* nameLengthP);
                          SQLSMALLINT* dataTypeP = $(SQLSMALLINT* dataTypeP);
                          SQLSMALLINT* decimalDigitsP = $(SQLSMALLINT* decimalDigitsP);
                          SQLSMALLINT* nullableP = $(SQLSMALLINT* nullableP);
                          SQLULEN* colSizeP = $(SQLULEN* colSizeP);
                          SQLWCHAR* tabNameP = $(SQLWCHAR* tabNameP);
               
                          ret = SQLDescribeColW(hstmt, $(SQLUSMALLINT colPos'), tabNameP, 16 * 128, nameLengthP, dataTypeP, colSizeP, decimalDigitsP, nullableP);
                          return ret;
                      }|]
               case isSuccessful ret  of
                 False -> getErrors ret (SQLSTMTRef hstmt) >>= throwSQLException
                 True -> do
                   nameLength <- peek nameLengthP
                   tableName <- fromPtr (castPtr tabNameP) (fromIntegral nameLength)
                   dataType <- peek dataTypeP
                   decimalDigits <- peek decimalDigitsP
                   cSize <- peek colSizeP
                   nullable <- peek nullableP
                   pure $ ColDescriptor
                    { colName = tableName
                    , colPosition = colPos'
                    , colDataType = SQLType dataType
                    , colSize = fromIntegral cSize
                    , colDecimalDigit = fromIntegral decimalDigits
                    , colIsNullable = case NullableFieldDesc nullable of
                        SQL_NO_NULLS         -> Just False
                        SQL_NULLABLE         -> Just True
                        SQL_NULLABLE_UNKNOWN -> Nothing
#if __GLASGOW_HASKELL__ < 820
                        _                    -> error "Panic: impossible case"
#endif
                    }
  
isSuccessful :: ResIndicator -> Bool
isSuccessful SQL_SUCCESS           = True
isSuccessful SQL_SUCCESS_WITH_INFO = True
isSuccessful _                     = False

extractVal :: Storable t => ColBufferType 'ColBind t -> IO t
extractVal cbuff = case cbuff of
  ColBindBuffer _ cbuffPtr -> withForeignPtr cbuffPtr peek

extractWith ::
  Storable t =>
  ColBufferType 'ColBind t ->
  (CLong -> Ptr t -> IO b) ->
  IO b
extractWith cbuff f = case cbuff of
  ColBindBuffer bufSizeFP cbuffPtr -> do
    bufSize <- peekFP bufSizeFP
    withForeignPtr cbuffPtr (f bufSize)

castColBufferPtr ::
  (Coercible t1 t2) =>
  ColBufferType bt t1 ->
  ColBufferType bt t2
castColBufferPtr cbuff = case cbuff of
  ColBindBuffer lenOrIndFP cbuffPtr ->
    ColBindBuffer lenOrIndFP (castForeignPtr cbuffPtr)
  GetDataUnboundBuffer k ->
    GetDataUnboundBuffer (\a accf -> k a $
                       \bf l -> accf bf l . castPtr)
  GetDataBoundBuffer act ->
    GetDataBoundBuffer $ do
      (fptr, lenOrInd) <- act
      pure (castForeignPtr fptr, lenOrInd)

boundWith ::
  ColBufferType 'GetDataBound t ->
  (CLong -> Ptr t -> IO a)       ->
  IO a
boundWith (GetDataBoundBuffer io) f = do
  (fptr, fstrOrIndPtr) <- io
  withForeignPtr fptr $ \ptr ->
    withForeignPtr fstrOrIndPtr $ \strOrIndPtr -> do
      strOrInd <- peek strOrIndPtr
      f strOrInd ptr

unboundWith :: 
  Storable t =>
  ColBufferType 'GetDataUnbound t ->
  a ->
  (CLong -> CLong -> Ptr t -> a -> IO a) ->
  IO a
unboundWith cbuff a f =
  case cbuff of
    GetDataUnboundBuffer k -> k a f

data ColBufferTypeK =
    ColBind
  | GetDataBound
  | GetDataUnbound
  
data ColBufferType (k :: ColBufferTypeK) t where
  ColBindBuffer :: ForeignPtr CLong -> ForeignPtr t -> ColBufferType 'ColBind t
  GetDataBoundBuffer :: IO (ForeignPtr t, ForeignPtr CLong) -> ColBufferType 'GetDataBound t
  GetDataUnboundBuffer :: (forall a. a -> (CLong -> CLong -> Ptr t -> a -> IO a) -> IO a) -> ColBufferType 'GetDataUnbound t

colBindBuffer :: ForeignPtr CLong -> ForeignPtr t -> ColBufferType 'ColBind t
colBindBuffer = ColBindBuffer

getDataUnboundBuffer ::
  (forall a. a -> (CLong -> CLong -> Ptr t -> a -> IO a) -> IO a) ->
  ColBufferType 'GetDataUnbound t
getDataUnboundBuffer = GetDataUnboundBuffer

getDataBoundBuffer ::
  IO (ForeignPtr t, ForeignPtr CLong) ->
  ColBufferType 'GetDataBound t
getDataBoundBuffer = GetDataBoundBuffer

type family GetColBufferType t where
  GetColBufferType (CGetDataUnbound _) = 'GetDataUnbound
  GetColBufferType (CGetDataBound _)   = 'GetDataBound  
  GetColBufferType _                   = 'ColBind

newtype CGetDataBound a = CGetDataBound { getCGetDataBound :: a }
                   deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

newtype CGetDataUnbound a = CGetDataUnbound { getCGetDataUnbound :: a }
                   deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

newtype CSized (size :: Nat) a = CSized { getCSized :: a }
                              deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance (KnownNat n) => IsString (Sized n T.Text) where
  fromString = Sized . T.pack . lengthCheck
    where lengthCheck x = case length x > fromIntegral n of
            True -> error "Panic: string size greater than sized parameter"
            False -> x

          n = natVal (Proxy :: Proxy n)

instance (KnownNat n) => IsString (Sized n ASCIIText) where
  fromString = Sized . ASCIIText . lengthCheck . getASCIIText . fromString
    where n = natVal (Proxy :: Proxy n)
          lengthCheck x = case T.length x > fromIntegral n of
            True -> error "Panic: string size greater than sized parameter"
            False -> x

instance IsString ASCIIText where
  fromString = ASCIIText . T.pack . checkAscii
    where checkAscii = map (\a -> case isAscii a of
                               True -> a
                               False -> error $ "Panic: non ascii character in ASCIIText " ++ show a)
  
newtype Sized (size :: Nat) a = Sized { getSized :: a }
                              deriving (Generic, Show, Eq, Ord)

newtype ColBuffer t = ColBuffer
  { getColBuffer :: ColBufferType (GetColBufferType t) t
  } 
  
fetchRows :: HSTMT a -> IO r -> IO (Vector r, ResIndicator)
fetchRows hstmt rowP = do
  retRef <- newIORef SQL_SUCCESS
  rows <- flip V.unfoldrM () $ \_ -> do
    res <- sqlFetch hstmt
    case ResIndicator $ fromIntegral res of
      SQL_SUCCESS -> do
        r <- rowP
        pure $ Just (r, ())
    
      ret -> atomicModifyIORef' retRef (\r -> (ret, r)) *> pure Nothing
  ret <- readIORef retRef
  pure (rows, ret)

sqlRowCount :: HSTMT a -> IO Int64
sqlRowCount stmt = do
  (rcountFP :: ForeignPtr CLong) <- mallocForeignPtr
  ret <- fmap ResIndicator $ withForeignPtr rcountFP $ \rcountP -> do
    [C.block| int {
        SQLRETURN ret = 0;
        SQLHSTMT hstmt = $(SQLHSTMT hstmt);

        ret = SQLRowCount(hstmt, $(SQLLEN* rcountP));

        return ret;
    }|]

  case isSuccessful ret of
    True -> fromIntegral <$> peekFP rcountFP
    False -> do
      errs <- getErrors ret (SQLSTMTRef hstmt)
      throwSQLException errs
  where
    hstmt = getHSTMT stmt


data FieldDescriptor t = FieldDescriptor

initColPos :: IO ColPos
initColPos = ColPos <$> newIORef 1

getCurrentColDescriptor :: HSTMT a -> IO ColDescriptor
getCurrentColDescriptor hstmt = do
  let (ColPos wref) = colPos hstmt
  currColPos <- readIORef wref
  sqlDescribeCol (getHSTMT hstmt) ( currColPos)

getCurrentColDescriptorAndMove :: HSTMT a -> IO ColDescriptor
getCurrentColDescriptorAndMove hstmt = do
  let (ColPos wref) = colPos hstmt
  currColPos <- atomicModifyIORef' wref (\w -> (w +1, w))
  let actualColPos = fromIntegral currColPos
      expectedColSize = numResultCols hstmt
  when (expectedColSize < actualColPos) $
    throwIO (SQLNumResultColsException expectedColSize actualColPos)
  res <- sqlDescribeCol (getHSTMT hstmt) (fromIntegral currColPos)
  pure res

nextColPos :: HSTMT a -> IO ()
nextColPos hstmt = do
  let (ColPos wref) = colPos hstmt
  atomicModifyIORef' wref (\w -> (w +1, ()))

getColPos :: HSTMT a -> IO CUShort
getColPos hstmt = do
  let (ColPos wref) = colPos hstmt
  readIORef wref

type Query = T.Text

query :: forall r.(FromRow r) => Connection -> Query -> IO (Vector r)
query = queryWith fromRow 

queryWith :: forall r.RowParser r -> Connection -> Query -> IO (Vector r)
queryWith (RowParser colBuf rowPFun) con q = do
  withHSTMT con $ \hstmt -> do
    nrcs <- sqldirect con (getHSTMT hstmt) q
    colBuffer <- colBuf ((coerce hstmt { numResultCols = nrcs }) :: HSTMT ())
    (rows, ret) <- fetchRows hstmt (rowPFun colBuffer)
    case ret of
          SQL_SUCCESS           -> pure rows
          SQL_SUCCESS_WITH_INFO -> pure rows
          SQL_NO_DATA           -> pure rows
          _                     -> do
            errs <- getErrors ret (SQLSTMTRef $ getHSTMT hstmt)
            throwSQLException errs

execute :: Connection -> Query -> IO Int64
execute con q = do
  withHSTMT con $ \hstmt -> do
    _ <- sqldirect con (getHSTMT hstmt) q
    sqlRowCount hstmt
  
data RowParser t =
  forall rowbuff.
  RowParser { rowBuffer    :: HSTMT () -> IO rowbuff
            , runRowParser :: rowbuff -> IO t
            }

instance Functor RowParser where
  fmap f (RowParser b rpf) = RowParser b $ \b' -> do
    res <- rpf b'
    pure (f res)

instance Applicative RowParser where
  pure a = RowParser (pure . const ()) (const (pure a))
  (RowParser b1 f) <*> (RowParser b2 a) =
    RowParser (\hstmt -> (,) <$> b1 hstmt <*> b2 hstmt) $
    \(b1', b2') -> f b1' <*> a b2'

field :: forall f. FromField f => RowParser f
field = RowParser
        (\s ->
            sqlBindCol (restmt s :: HSTMT (ColBuffer (FieldBufferType f)))
        )
        fromField

restmt :: forall a b. HSTMT a -> HSTMT b
restmt (HSTMT stm cp ncs) = HSTMT stm cp ncs :: HSTMT b

class FromRow t where
  fromRow :: RowParser t

  default fromRow :: ( Generic t
                     , GFromRow (Rep t)
                     ) => RowParser t
  fromRow = to <$> gFromRow

class GFromRow (f :: * -> *) where
  gFromRow :: RowParser (f a)

instance (GFromRow f) => GFromRow (M1 c i f) where
  gFromRow = M1 <$> gFromRow 

instance GFromRow U1 where
  gFromRow = pure U1

instance (GFromRow f, GFromRow g) => GFromRow (f :*: g) where
  gFromRow = 
    (:*:) <$> gFromRow
          <*> gFromRow

instance (FromField a) => GFromRow (K1 k a) where
  gFromRow = K1 <$> field
    
instance (FromField a, FromField b) => FromRow (a, b) where
  fromRow =  (,) <$> field <*> field

instance FromField a => FromRow (Identity a) where
  fromRow = Identity <$> field

type FieldParser t = ColBuffer (FieldBufferType t) -> IO t

class ( SQLBindCol ((ColBuffer (FieldBufferType t)))
      ) => FromField t where
  type FieldBufferType t :: *
  fromField :: ColBuffer (FieldBufferType t) -> IO t

instance FromField Int where
  type FieldBufferType Int = CBigInt
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ fromIntegral v)
  
{-
instance FromField Int8 where
  type FieldBufferType Int8 = CTinyInt
  fromField = Value $ \i -> extractVal i >>= (\v -> pure $ fromIntegral v)
-}
  
instance FromField Int16 where
  type FieldBufferType Int16 = CSmallInt 
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ fromIntegral v)

instance FromField Int32 where
  type FieldBufferType Int32 = CLong
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ fromIntegral v)

instance FromField Int64 where
  type FieldBufferType Int64 = CBigInt
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ coerce v)

{-
instance FromField Word where
  type FieldBufferType Word = CUBigInt
  fromField = Value $ \i -> extractVal i >>= (\v -> pure $ fromIntegral v)
-}

instance FromField Word8 where
  type FieldBufferType Word8 = CUTinyInt
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ fromIntegral v)

{-
instance FromField Word16 where
  type FieldBufferType Word16 = CUSmallInt
  fromField = Value $ \i -> extractVal i >>= (\v -> pure $ fromIntegral v)

instance FromField Word32 where
  type FieldBufferType Word32 = CULong
  fromField = Value $ \i -> extractVal i >>= (\v -> pure $ fromIntegral v)

instance FromField Word64 where
  type FieldBufferType Word64 = CUBigInt
  fromField = Value $ \i -> extractVal i >>= (\v -> pure $ fromIntegral v)  
-}

{-
instance (KnownNat n) => FromField (Sized n T.Text) where
  type FieldBufferType (Sized n T.Text) = CSized n CWchar
  fromField = \v -> do
    extractWith (castColBufferPtr $ getColBuffer v) $ \bufSize cwcharP -> do
      putStrLn $ "BufSize: " ++ show bufSize      
      let clen = round ((fromIntegral bufSize :: Double) / 2) :: Word
      coerce <$> T.fromPtr (coerce (cwcharP :: Ptr CWchar)) (fromIntegral clen)      

instance (KnownNat n) => FromField (Sized n ASCIIText) where
  type FieldBufferType (Sized n ASCIIText) = CSized n CChar
  fromField = \v -> do
    extractWith (castColBufferPtr $ getColBuffer v) $ \bufSize ccharP -> do
      (Sized . ASCIIText . T.pack) <$> Foreign.C.peekCStringLen (ccharP, fromIntegral bufSize)
-}

instance FromField Double where
  type FieldBufferType Double = CDouble
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ coerce v)

instance FromField Float where
  type FieldBufferType Float = CFloat
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ coerce v)

instance FromField Bool where
  type FieldBufferType Bool = CBool
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ if v == 1 then True else False)

newtype ASCIIText = ASCIIText { getASCIIText :: T.Text }
                  deriving (Show, Eq, Generic)

instance FromField ASCIIText where
  type FieldBufferType ASCIIText = CGetDataUnbound CChar
  fromField = \v -> do
    bsb <- unboundWith (getColBuffer v) mempty $
      \_ bufSize ccharP acc -> do
        a <- BS.packCStringLen (coerce ccharP, fromIntegral bufSize)
        pure (acc <> BSB.byteString a)
    pure (ASCIIText . T.pack . BS8.unpack . LBS.toStrict $ BSB.toLazyByteString bsb)  

instance FromField ByteString where
  type FieldBufferType ByteString = CGetDataUnbound CBinary
  fromField = fmap LBS.toStrict . fromField

instance FromField LBS.ByteString where
  type FieldBufferType LBS.ByteString = CGetDataUnbound CBinary
  fromField = \v -> do
    bsb <- unboundWith (getColBuffer v) mempty $
      \bufSize lenOrInd ccharP acc -> do
        putStrLn $ "Len or ind: " ++ show lenOrInd
        let actBufSize = case fromIntegral lenOrInd of
                           SQL_NO_TOTAL -> bufSize
                           i | i > fromIntegral bufSize -> bufSize
                           len -> fromIntegral len
        a <- BS.packCStringLen (coerce ccharP, fromIntegral actBufSize)
        pure (acc <> BSB.byteString a)
    pure (BSB.toLazyByteString bsb)

instance FromField Image where
  type FieldBufferType Image = CGetDataUnbound CBinary
  fromField = fmap Image . fromField

instance FromField T.Text where
  type FieldBufferType T.Text = CGetDataUnbound CWchar
  fromField = \v -> do
    bsb <- unboundWith (getColBuffer v) mempty $
      \bufSize lenOrInd cwcharP acc -> do
        putStrLn $ "Bufsize and lenOrInd: " ++ show (bufSize, lenOrInd)
        let actBufSize = if fromIntegral lenOrInd == SQL_NO_TOTAL
                           then Left () -- (bufSize `div` 2) - 2
                           else Right lenOrInd
        a <- case actBufSize of
          Left _ -> F.peekCWString (coerce cwcharP)
          Right len -> F.peekCWStringLen (coerce cwcharP, fromIntegral len)
        pure (acc <> T.pack a)
    pure bsb

{-
instance FromField Money where
  type FieldBufferType Money = CDecimal CChar
  fromField = \v -> do
    bs <- extractWith (castColBufferPtr $ getColBuffer v) $ \bufSize ccharP -> do
        BS.packCStringLen (ccharP, fromIntegral bufSize)
    let res = BS8.unpack bs
    maybe (error $ "Parse failed for Money: " ++ show res)
          (pure . Money) (readMaybe $ res)

instance FromField SmallMoney where
  type FieldBufferType SmallMoney = CDecimal CDouble
  fromField = \v -> do
    extractVal (castColBufferPtr (getColBuffer v) :: ColBufferType 'ColBind CDouble) >>= (pure . SmallMoney . fromFloatDigits)
-}

instance FromField Day where
  type FieldBufferType Day = CDate
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ getDate v)

instance FromField TimeOfDay where
  type FieldBufferType TimeOfDay = CTimeOfDay
  fromField = \i -> do
    extractWith (getColBuffer i) $ \_ v -> do
      v' <- peek v
      pure $ getTimeOfDay v'
      
instance FromField LocalTime where
  type FieldBufferType LocalTime = CLocalTime
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ getLocalTime v)

instance FromField ZonedTime where
  type FieldBufferType ZonedTime = CZonedTime
  fromField = \i -> extractVal (getColBuffer i) >>= (\v -> pure $ Database.MSSQL.Internal.SQLTypes.getZonedTime v)

instance FromField UTCTime where
  type FieldBufferType UTCTime = FieldBufferType ZonedTime
  fromField = \v -> zonedTimeToUTC <$> fromField v

instance FromField UUID where
  type FieldBufferType UUID = UUID
  fromField = \i -> extractVal (getColBuffer i)

-- NOTE: There is no generic lengthOrIndicatorFP
instance FromField a => FromField (Maybe a) where
  type FieldBufferType (Maybe a) = FieldBufferType a
  fromField = \v -> do
    case getColBuffer v of
      ColBindBuffer fptr _ -> do 
        lengthOrIndicator <- peekFP fptr
        if lengthOrIndicator == fromIntegral SQL_NULL_DATA -- TODO: Only long worked not SQLINTEGER
          then pure Nothing
          else Just <$> (fromField v)
      GetDataBoundBuffer _ ->
          pure Nothing          
      GetDataUnboundBuffer _ ->
          pure Nothing
          -- fromField (ColBuffer (getDataUnboundBuffer $ \a accf -> k (Just a) $ \len ptr a -> if fromIntegral len == SQL_NULL_DATA then pure Nothing else Just <$> accf len ptr a))
  
instance FromField a => FromField (Identity a) where
  type FieldBufferType (Identity a) = FieldBufferType a
  fromField = \v ->
      Identity <$> (fromField v)

-- TODO: Is coerceColBuffer necessary? is it same as castColBufferPtr?
-- coerceColBuffer :: (Coercible a b) => ColBuffer a -> ColBuffer b
-- coerceColBuffer c = c {getColBuffer  = castForeignPtr $ getColBuffer c}

peekFP :: Storable t => ForeignPtr t -> IO t
peekFP fp = withForeignPtr fp peek

type SQLBindColM t = ReaderT ColPos IO (Either SQLErrors t)

class SQLBindCol t where
  sqlBindCol :: HSTMT t -> IO t

sqlBindColTpl :: forall t. (Typeable t) =>
                      HSTMT (ColBuffer t) ->
                      (Ptr SQLHSTMT -> ColDescriptor -> IO (ColBuffer t)) ->
                      IO (ColBuffer t)
sqlBindColTpl hstmt block = do
   let hstmtP = getHSTMT hstmt       
   cdesc <- getCurrentColDescriptorAndMove hstmt
   if match cdesc
     then block hstmtP cdesc
     else typeMismatch exps cdesc

     where match cdesc = colDataType cdesc `elem` exps
           exps        = maybe [] id (HM.lookup rep sqlMapping)
           rep         = typeOf (undefined :: t)

sqlBindColTplBound :: forall t. (Typeable t) =>
                      HSTMT (ColBuffer (CGetDataBound t)) ->
                      (Ptr SQLHSTMT -> ColDescriptor -> IO (ColBuffer (CGetDataBound t))) ->
                      IO (ColBuffer (CGetDataBound t))
sqlBindColTplBound hstmt block = do
   let hstmtP = getHSTMT hstmt       
   cdesc <- getCurrentColDescriptorAndMove hstmt
   if match cdesc
     then block hstmtP cdesc
     else typeMismatch exps cdesc

     where match cdesc = colDataType cdesc `elem` exps
           exps        = maybe [] id (HM.lookup rep sqlMapping)
           rep         = typeOf (undefined :: t)

sqlBindColTplUnbound :: forall t. (Typeable t) =>
                      HSTMT (ColBuffer (CGetDataUnbound t)) ->
                      (Ptr SQLHSTMT -> ColDescriptor -> IO (ColBuffer (CGetDataUnbound t))) ->
                      IO (ColBuffer (CGetDataUnbound t))
sqlBindColTplUnbound hstmt block = do
   let hstmtP = getHSTMT hstmt       
   cdesc <- getCurrentColDescriptorAndMove hstmt
   if match cdesc
     then block hstmtP cdesc
     else typeMismatch exps cdesc

     where match cdesc = colDataType cdesc `elem` exps
           exps        = maybe [] id (HM.lookup rep sqlMapping)
           rep         = typeOf (undefined :: t)

newtype CBinary = CBinary { getCBinary :: CUChar }
                deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CBinary) where
  sqlBindCol hstmt =
    sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let
        cpos = colPosition cdesc
        bufSize = fromIntegral (colSize cdesc)
      binFP <- mallocForeignPtrBytes (fromIntegral bufSize)
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr binFP $ \binP -> do
        [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_BINARY, $(SQLCHAR* binP), $(SQLLEN bufSize), lenOrInd);
          return ret;
        }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP (coerce binFP)))

instance SQLBindCol (ColBuffer (CGetDataUnbound CBinary)) where
  sqlBindCol hstmt = 
   sqlBindColTplUnbound hstmt block
   
     where block hstmtP cdesc = do
             let bufSize = fromIntegral (32 :: Int)
             binFP <- mallocForeignPtrBytes (fromIntegral bufSize)
             lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
             let cpos = colPosition cdesc
                 cbuf = getDataUnboundBuffer (\acc f ->
                                               fetchBytes hstmtP binFP lenOrIndFP bufSize cpos f acc)
                        
             pure $ (ColBuffer cbuf)

           fetchBytes hstmtP binFP lenOrIndFP bufSize cpos f = go           
             where go acc = do
                     ret <- fmap ResIndicator $ withForeignPtr binFP $ \binP -> do
                      [C.block| int {
                        SQLRETURN ret = 0;
                        SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
                        SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
                        ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_BINARY, $(SQLCHAR* binP), $(SQLLEN bufSize), lenOrInd);
                        return ret;
                      }|]
                     case isSuccessful ret of
                       True -> do
                           lengthOrInd <- peekFP lenOrIndFP
                           putStrLn $ "status: " ++ show (ret, lengthOrInd)
                           acc' <- withForeignPtr binFP $ \tptr -> f bufSize lengthOrInd (coerce tptr) acc
                           go acc'
                       False -> pure acc

instance SQLBindCol (ColBuffer (CGetDataUnbound CChar)) where
  sqlBindCol hstmt = 
   sqlBindColTplUnbound hstmt block
   
     where block hstmtP cdesc = do
             let bufSize = fromIntegral (20 :: Int)
             chrFP <- mallocForeignPtrBytes (fromIntegral bufSize)
             lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
             let cpos = colPosition cdesc
                 cbuf = getDataUnboundBuffer (\acc f ->
                                               fetchBytes hstmtP chrFP lenOrIndFP bufSize cpos f acc)
                        
             pure $ (ColBuffer cbuf)

           fetchBytes hstmtP chrFP lenOrIndFP bufSize cpos f = go
           
             where go acc = do
                     ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrP -> do
                      [C.block| int {
                        SQLRETURN ret = 0;
                        SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
                        SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
                        ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_CHAR, $(SQLCHAR* chrP), $(SQLLEN bufSize), lenOrInd);
                        return ret;
                      }|]
                     case isSuccessful ret of
                       True -> do
                           lengthOrInd <- peekFP lenOrIndFP
                           {-
                           let actBufSize = case fromIntegral lengthOrInd of
                                              SQL_NO_TOTAL                 -> bufSize - 1
                                              i | i >= fromIntegral bufSize -> bufSize - 1
                                              _                            -> lengthOrInd
                           -}
                           acc' <- withForeignPtr chrFP $ \tptr -> f bufSize lengthOrInd (coerce tptr) acc
                           go acc'
                       False -> pure acc

instance SQLBindCol (ColBuffer CChar) where
  sqlBindCol hstmt =
    sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let
        cpos = colPosition cdesc
        bufSize = {-fromIntegral $-} (fromIntegral (colSize cdesc + 1)) -- colSizeAdjustment hstmt (fromIntegral (colSize cdesc + 1))
      -- print $ "colSize as said: " ++ show (colSize cdesc)
      chrFP <- mallocForeignPtrBytes (fromIntegral bufSize)
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrp -> do
        [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_CHAR, $(SQLCHAR* chrp), $(SQLLEN bufSize), lenOrInd);
          return ret;
        }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP chrFP) )

instance SQLBindCol (ColBuffer CWchar) where
  sqlBindCol hstmt =
    sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let cpos = colPosition cdesc
          bufSize = fromIntegral (colSize cdesc * 4 + 1) -- colSizeAdjustment hstmt (fromIntegral (colSize cdesc + 1))
      print $ "colSize as said: " ++ show (colSize cdesc, bufSize)          
      txtFP <- mallocForeignPtrBytes (fromIntegral bufSize)
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr txtFP $ \txtP -> do
        [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_WCHAR, $(SQLWCHAR* txtP), $(SQLLEN bufSize), lenOrInd);
          return ret;
        }|]
      peekFP lenOrIndFP >>= \a -> putStrLn $ "LenOrInd: " ++ show a
      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP $ coerce txtFP))

instance SQLBindCol (ColBuffer (CGetDataUnbound CWchar)) where
  sqlBindCol hstmt = 
   sqlBindColTplUnbound hstmt block
   
     where block hstmtP cdesc = do
             let bufSize = fromIntegral (36 :: Int)
             txtFP <- mallocForeignPtrBytes (fromIntegral bufSize)
             lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
             let cpos = colPosition cdesc
                 cbuf = getDataUnboundBuffer (\acc f ->
                                               fetchText hstmtP txtFP lenOrIndFP bufSize cpos f acc)
                        
             pure $ (ColBuffer cbuf)

           fetchText hstmtP txtFP lenOrIndFP bufSize cpos f = go
           
             where go acc = do
                     ret <- fmap ResIndicator $ withForeignPtr txtFP $ \txtP -> do
                      [C.block| int {
                        SQLRETURN ret = 0;
                        SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
                        SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
                        ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_WCHAR, $(SQLWCHAR* txtP), $(SQLLEN bufSize), lenOrInd);
                        return ret;
                      }|]
                     case isSuccessful ret of
                       True -> do
                           msgs <- getMessages (SQLSTMTRef hstmtP)
                           putStrLn $ "Message: " ++ show (msgs, ret, ret == SQL_SUCCESS)
                           lengthOrInd <- peekFP lenOrIndFP
                           {-
                           let actBufSize = case fromIntegral lengthOrInd of
                                              SQL_NO_TOTAL -> bufSize - 2
                                              _            -> lengthOrInd
                           -}
                           acc' <- withForeignPtr txtFP $ \tptr -> f bufSize lengthOrInd (coerce tptr) acc
                           go acc'
                       False -> pure acc

{-
newtype CDecimal a = CDecimal a
  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer (CDecimal CDouble)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce hstmt :: HSTMT (ColBuffer CDouble))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)

instance SQLBindCol (ColBuffer (CDecimal CFloat)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce hstmt :: HSTMT (ColBuffer CFloat))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)
-}
{-
instance SQLBindCol (ColBuffer (CDecimal CChar)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce (adjustColSize (+2) hstmt) :: HSTMT (ColBuffer CChar))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)
-}
{-
instance (KnownNat n) => SQLBindCol (ColBuffer (CSized n CChar)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce hstmt :: HSTMT (ColBuffer CChar))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)

instance (KnownNat n) => SQLBindCol (ColBuffer (CSized n CWchar)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce hstmt :: HSTMT (ColBuffer CWchar))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)
-}
{-
instance (KnownNat n) => SQLBindCol (ColBuffer (CSized n CBinary)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce (adjustColSize (const bufSize) hstmt) :: HSTMT (ColBuffer CBinary))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)

    where bufSize = fromIntegral (natVal (Proxy :: Proxy n))

instance (KnownNat n) => SQLBindCol (ColBuffer (CSized n CWchar)) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce (adjustColSize (const bufSize) hstmt) :: HSTMT (ColBuffer CWchar))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)

    where bufSize = fromIntegral ((natVal (Proxy :: Proxy n)) * 4) + 2

instance (KnownNat n) => SQLBindCol (ColBuffer (CSized n (CDecimal CChar))) where
  sqlBindCol hstmt = do
    ebc <- sqlBindCol (coerce (adjustColSize (const bufSize) hstmt) :: HSTMT (ColBuffer CChar))
    pure (fmap (ColBuffer . castColBufferPtr . getColBuffer) ebc)

    where bufSize = fromIntegral (natVal (Proxy :: Proxy n)) + 3
-}

newtype CUTinyInt = CUTinyInt CUChar
                  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CUTinyInt) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
        chrFP <- mallocForeignPtr
        let cpos = colPosition cdesc
        lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
        ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrP -> do
         [C.block| int {
             SQLRETURN ret = 0;
             SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
             SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
             ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_UTINYINT, $(SQLCHAR* chrP), sizeof(SQLCHAR), lenOrInd);
             return ret;
         }|]
        returnWithRetCode ret (SQLSTMTRef hstmtP) $
          (ColBuffer (colBindBuffer lenOrIndFP $ castForeignPtr chrFP))

instance SQLBindCol (ColBuffer (CGetDataBound CUTinyInt)) where
  sqlBindCol hstmt =  
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
        chrFP <- mallocForeignPtr
        let cpos = colPosition cdesc
        lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
        ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrP -> do
         [C.block| int {
             SQLRETURN ret = 0;
             SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
             SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
             ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_UTINYINT, $(SQLCHAR* chrP), sizeof(SQLCHAR), lenOrInd);
             return ret;
         }|]
        returnWithRetCode ret (SQLSTMTRef hstmtP) $
          (coerce chrFP, lenOrIndFP)


newtype CTinyInt = CTinyInt CChar
                  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CTinyInt) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      chrFP <- mallocForeignPtr
      let cpos = colPosition cdesc
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrP -> do
        [C.block| int {
            SQLRETURN ret = 0;
            SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
            SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
            ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_TINYINT, $(SQLCHAR* chrP), sizeof(SQLCHAR), lenOrInd);
            return ret;
        }|]
      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP $ castForeignPtr chrFP))

instance SQLBindCol (ColBuffer CLong) where
  sqlBindCol hstmt = 
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let cpos = colPosition cdesc
      intFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr intFP $ \intP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_LONG, $(SQLINTEGER* intP), sizeof(SQLINTEGER), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP intFP))


instance SQLBindCol (ColBuffer (CGetDataBound CLong)) where
  sqlBindCol hstmt = 
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
      let cpos = colPosition cdesc
      intFP :: ForeignPtr CLong <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr intFP $ \intP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_LONG, $(SQLINTEGER* intP), sizeof(SQLINTEGER), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (coerce intFP, lenOrIndFP)

instance SQLBindCol (ColBuffer CULong) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let cpos = colPosition cdesc
      intFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr intFP $ \intP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_ULONG, $(SQLUINTEGER* intP), sizeof(SQLUINTEGER), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP intFP))

newtype CSmallInt = CSmallInt CShort
                  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CSmallInt) where
  sqlBindCol hstmt = 
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do 
       let cpos = colPosition cdesc
       shortFP <- mallocForeignPtr           
       lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
       ret <- fmap ResIndicator $ withForeignPtr shortFP $ \shortP -> do
        [C.block| int {
            SQLRETURN ret = 0;
            SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
            SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
            ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_SHORT, $(SQLSMALLINT* shortP), sizeof(SQLSMALLINT), lenOrInd);
            return ret;
        }|]

       returnWithRetCode ret (SQLSTMTRef hstmtP) $
         (ColBuffer (colBindBuffer lenOrIndFP $ coerce shortFP))

instance SQLBindCol (ColBuffer (CGetDataBound CSmallInt)) where
  sqlBindCol hstmt = 
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do 
       let cpos = colPosition cdesc
       shortFP <- mallocForeignPtr           
       lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
       ret <- fmap ResIndicator $ withForeignPtr shortFP $ \shortP -> do
        [C.block| int {
            SQLRETURN ret = 0;
            SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
            SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
            ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_SHORT, $(SQLSMALLINT* shortP), sizeof(SQLSMALLINT), lenOrInd);
            return ret;
        }|]

       returnWithRetCode ret (SQLSTMTRef hstmtP) $
         (coerce shortFP, lenOrIndFP)


newtype CUSmallInt = CUSmallInt CShort
                  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CUSmallInt) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let cpos = colPosition cdesc
      shortFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr shortFP $ \shortP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_USHORT, $(SQLUSMALLINT* shortP), sizeof(SQLUSMALLINT), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP $ coerce shortFP))

instance SQLBindCol (ColBuffer CFloat) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let cpos = colPosition cdesc
      floatFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr floatFP $ \floatP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_FLOAT, $(SQLREAL* floatP), sizeof(SQLREAL), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP floatFP))

instance SQLBindCol (ColBuffer (CGetDataBound CFloat)) where
  sqlBindCol hstmt =
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
      let cpos = colPosition cdesc
      floatFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr floatFP $ \floatP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_FLOAT, $(SQLREAL* floatP), sizeof(SQLREAL), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (coerce floatFP, lenOrIndFP)

instance SQLBindCol (ColBuffer CDouble) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do    
      let cpos = colPosition cdesc
      floatFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr floatFP $ \floatP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_DOUBLE, $(SQLDOUBLE* floatP), sizeof(SQLDOUBLE), lenOrInd);
           return ret;
       }|]
      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP floatFP))

instance SQLBindCol (ColBuffer (CGetDataBound CDouble)) where
  sqlBindCol hstmt =
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
      let cpos = colPosition cdesc
      floatFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr floatFP $ \floatP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_DOUBLE, $(SQLDOUBLE* floatP), sizeof(SQLDOUBLE), lenOrInd);
           return ret;
       }|]
      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (coerce floatFP, lenOrIndFP)

instance SQLBindCol (ColBuffer CBool) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do        
      let cpos = colPosition cdesc
      chrFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_BIT, $(SQLCHAR* chrP), sizeof(1), lenOrInd);
           return ret;
       }|]
      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP $ castForeignPtr chrFP))

instance SQLBindCol (ColBuffer (CGetDataBound CBool)) where
  sqlBindCol hstmt =
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do    
      let cpos = colPosition cdesc
      chrFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr chrFP $ \chrP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_BIT, $(SQLCHAR* chrP), sizeof(1), lenOrInd);
           return ret;
       }|]
      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (coerce chrFP, lenOrIndFP)

instance SQLBindCol (ColBuffer CDate) where
  sqlBindCol hstmt = do
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
      let cpos = colPosition cdesc
      dateFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr dateFP $ \dateP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_TYPE_DATE, $(SQL_DATE_STRUCT* dateP), sizeof(SQL_DATE_STRUCT), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP dateFP))

instance SQLBindCol (ColBuffer (CGetDataBound CDate)) where
  sqlBindCol hstmt = do
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do    
      let cpos = colPosition cdesc
      dateFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr dateFP $ \dateP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_TYPE_DATE, $(SQL_DATE_STRUCT* dateP), sizeof(SQL_DATE_STRUCT), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
         (coerce dateFP, lenOrIndFP)

newtype CBigInt = CBigInt CLLong
                  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CBigInt) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do    
      let cpos = colPosition cdesc
      llongFP <- mallocForeignPtr
      lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
      ret <- fmap ResIndicator $ withForeignPtr llongFP $ \llongP -> do
       [C.block| int {
           SQLRETURN ret = 0;
           SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
           SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
           ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_SBIGINT, $(long long* llongP), sizeof(long long), lenOrInd);
           return ret;
       }|]

      returnWithRetCode ret (SQLSTMTRef hstmtP) $
        (ColBuffer (colBindBuffer lenOrIndFP $ coerce llongFP))

instance SQLBindCol (ColBuffer (CGetDataBound CBigInt)) where
  sqlBindCol hstmt =
      sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
       let cpos = colPosition cdesc
       llongFP :: ForeignPtr CLLong <- mallocForeignPtr
       lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
       ret <- fmap ResIndicator $ withForeignPtr llongFP $ \llongP -> do
        [C.block| int {
            SQLRETURN ret = 0;
            SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
            SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
            ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_SBIGINT, $(long long* llongP), sizeof(long long), lenOrInd);
            return ret;
        }|]

       returnWithRetCode ret (SQLSTMTRef hstmtP) $
         (coerce llongFP, lenOrIndFP)

newtype CUBigInt = CUBigInt CULLong
                  deriving (Show, Eq, Ord, Enum, Bounded, Num, Integral, Real, Storable)

instance SQLBindCol (ColBuffer CUBigInt) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do    
     let cpos = colPosition cdesc
     llongFP <- mallocForeignPtr           
     lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
     ret <- fmap ResIndicator $ withForeignPtr llongFP $ \llongP -> do
      [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_UBIGINT, $(unsigned long long* llongP), sizeof(unsigned long long), lenOrInd);
          return ret;
      }|]

     returnWithRetCode ret (SQLSTMTRef hstmtP) $
       (ColBuffer (colBindBuffer lenOrIndFP $ coerce llongFP))

instance SQLBindCol (ColBuffer CTimeOfDay) where
  sqlBindCol hstmt = do
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do    
     let cpos = colPosition cdesc
     todFP <- mallocForeignPtr 
     lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
     ret <- fmap ResIndicator $ withForeignPtr todFP $ \todP -> do
      [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN bufSize = sizeof(SQL_SS_TIME2_STRUCT);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_BINARY, $(SQL_SS_TIME2_STRUCT* todP), sizeof(SQL_SS_TIME2_STRUCT), lenOrInd);
          return ret;
      }|]

     returnWithRetCode ret (SQLSTMTRef hstmtP) $
       (ColBuffer (colBindBuffer lenOrIndFP todFP))

instance SQLBindCol (ColBuffer (CGetDataBound CTimeOfDay)) where
  sqlBindCol hstmt = do
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
     let cpos = colPosition cdesc
     todFP <- mallocForeignPtr 
     lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
     ret <- fmap ResIndicator $ withForeignPtr todFP $ \todP -> do
      [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN bufSize = sizeof(SQL_SS_TIME2_STRUCT);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_BINARY, $(SQL_SS_TIME2_STRUCT* todP), sizeof(SQL_SS_TIME2_STRUCT), lenOrInd);
          return ret;
      }|]

     returnWithRetCode ret (SQLSTMTRef hstmtP) $
       (coerce todFP, lenOrIndFP)

instance SQLBindCol (ColBuffer CLocalTime) where
  sqlBindCol hstmt = do
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
       let cpos = colPosition cdesc
       ltimeFP <- mallocForeignPtr
       lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
       ret <- fmap ResIndicator $ withForeignPtr ltimeFP $ \ltimeP -> do
        [C.block| int {
            SQLRETURN ret = 0;
            SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
            SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
            ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_TYPE_TIMESTAMP, $(SQL_TIMESTAMP_STRUCT* ltimeP), sizeof(SQL_TIMESTAMP_STRUCT), lenOrInd);
            return ret;
        }|]
       returnWithRetCode ret (SQLSTMTRef hstmtP) $
         (ColBuffer (colBindBuffer lenOrIndFP ltimeFP))

instance SQLBindCol (ColBuffer (CGetDataBound CLocalTime)) where
  sqlBindCol hstmt = do
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do
       let cpos = colPosition cdesc
       ltimeFP <- mallocForeignPtr
       lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
       ret <- fmap ResIndicator $ withForeignPtr ltimeFP $ \ltimeP -> do
        [C.block| int {
            SQLRETURN ret = 0;
            SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
            SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
            ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_TYPE_TIMESTAMP, $(SQL_TIMESTAMP_STRUCT* ltimeP), sizeof(SQL_TIMESTAMP_STRUCT), lenOrInd);
            return ret;
        }|]
       returnWithRetCode ret (SQLSTMTRef hstmtP) $
         (coerce ltimeFP, lenOrIndFP)

instance SQLBindCol (ColBuffer CZonedTime) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
     let cpos = colPosition cdesc
     ltimeFP <- mallocForeignPtr
     lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
     ret <- fmap ResIndicator $ withForeignPtr ltimeFP $ \ltimeP -> do
      [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_BINARY, $(SQL_SS_TIMESTAMPOFFSET_STRUCT* ltimeP), sizeof(SQL_SS_TIMESTAMPOFFSET_STRUCT), lenOrInd);
          return ret;
      }|]

     returnWithRetCode ret (SQLSTMTRef hstmtP) $
       (ColBuffer (colBindBuffer lenOrIndFP ltimeFP))

instance SQLBindCol (ColBuffer (CGetDataBound CZonedTime)) where
  sqlBindCol hstmt =
   sqlBindColTplBound hstmt $ \hstmtP cdesc -> pure $ ColBuffer $ getDataBoundBuffer $ do    
     let cpos = colPosition cdesc
     ltimeFP <- mallocForeignPtr
     lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
     ret <- fmap ResIndicator $ withForeignPtr ltimeFP $ \ltimeP -> do
      [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLGetData(hstmt, $(SQLUSMALLINT cpos), SQL_C_BINARY, $(SQL_SS_TIMESTAMPOFFSET_STRUCT* ltimeP), sizeof(SQL_SS_TIMESTAMPOFFSET_STRUCT), lenOrInd);
          return ret;
      }|]

     returnWithRetCode ret (SQLSTMTRef hstmtP) $
       (coerce ltimeFP, lenOrIndFP)

instance SQLBindCol (ColBuffer UUID) where
  sqlBindCol hstmt =
   sqlBindColTpl hstmt $ \hstmtP cdesc -> do
     let cpos = colPosition cdesc
     uuidFP <- mallocForeignPtr
     lenOrIndFP :: ForeignPtr CLong <- mallocForeignPtr
     ret <- fmap ResIndicator $ withForeignPtr uuidFP $ \uuidP -> do
      [C.block| int {
          SQLRETURN ret = 0;
          SQLHSTMT hstmt = $(SQLHSTMT hstmtP);
          SQLLEN* lenOrInd = $fptr-ptr:(SQLLEN* lenOrIndFP);
          ret = SQLBindCol(hstmt, $(SQLUSMALLINT cpos), SQL_C_GUID, $(SQLGUID* uuidP), 16, lenOrInd);
          return ret;
      }|]

     returnWithRetCode ret (SQLSTMTRef hstmtP) $
       (ColBuffer (colBindBuffer lenOrIndFP uuidFP))

typeMismatch :: (MonadIO m) => [SQLType] -> ColDescriptor -> m a
typeMismatch expTys col =
  let emsg = case expTys of
        [e] -> "Expected a type: " <> show e
        es  -> "Expected one of types: " <> show es
      msg = emsg <> ", but got a type: " <> show colType <> colMsg <> hintMsg
      hintMsg = "  HINT: " <> show colType <> " is mapped to the following " <> show matches
      colType = colDataType col
      matches = HM.foldlWithKey' (\a k v -> case colType `elem` v of
                                     True -> k : a
                                     False -> a
                                 ) [] sqlMapping
      colMsg = case T.unpack (colName col) of
        "" -> ""
        _  -> ", in a column: " <> T.unpack (colName col)
      se = SQLError { sqlState = ""
                    , sqlMessage = T.pack msg
                    , sqlReturn = -1
                    }
  in  throwSQLException (SQLErrors [ se ])
                      
inQuotes :: Builder -> Builder
inQuotes b = quote `mappend` b `mappend` quote
  where quote = BSB.char8 '\''  

#if  !MIN_VERSION_GLASGOW_HASKELL(8,2,0,0)
newtype CBool = CBool Word8
  deriving (Num, Eq, Storable)
#endif

newtype ResIndicator = ResIndicator C.CInt
  deriving (Show, Read, Eq, Storable, Num, Integral, Real, Enum, Ord)

pattern SQL_NULL_DATA :: ResIndicator
pattern SQL_NULL_DATA <- ((ResIndicator [C.pure| SQLRETURN {SQL_NULL_DATA} |] ==) -> True) where
  SQL_NULL_DATA = ResIndicator [C.pure| SQLRETURN {SQL_NULL_DATA} |]  

pattern SQL_NO_TOTAL :: ResIndicator
pattern SQL_NO_TOTAL <- ((ResIndicator [C.pure| SQLRETURN {SQL_NO_TOTAL} |] ==) -> True) where
  SQL_NO_TOTAL = ResIndicator [C.pure| SQLRETURN {SQL_NO_TOTAL} |]

pattern SQL_DATA_AT_EXEC :: ResIndicator
pattern SQL_DATA_AT_EXEC <- ((ResIndicator [C.pure| SQLRETURN {SQL_DATA_AT_EXEC} |] ==) -> True) where
  SQL_DATA_AT_EXEC = ResIndicator [C.pure| SQLRETURN {SQL_DATA_AT_EXEC} |]

pattern SQL_SUCCESS :: ResIndicator
pattern SQL_SUCCESS <- ((ResIndicator [C.pure| SQLRETURN {SQL_SUCCESS} |] ==) -> True) where
  SQL_SUCCESS = ResIndicator [C.pure| SQLRETURN {SQL_SUCCESS} |]

pattern SQL_SUCCESS_WITH_INFO :: ResIndicator
pattern SQL_SUCCESS_WITH_INFO <- ((ResIndicator [C.pure| SQLRETURN {SQL_SUCCESS_WITH_INFO} |] ==) -> True) where
  SQL_SUCCESS_WITH_INFO = ResIndicator [C.pure| SQLRETURN {SQL_SUCCESS_WITH_INFO} |]

pattern SQL_NO_DATA :: ResIndicator
pattern SQL_NO_DATA <- ((ResIndicator [C.pure| SQLRETURN {SQL_NO_DATA} |] ==) -> True) where
  SQL_NO_DATA = ResIndicator [C.pure| SQLRETURN {SQL_NO_DATA} |]

pattern SQL_ERROR :: ResIndicator
pattern SQL_ERROR <- ((ResIndicator [C.pure| SQLRETURN {SQL_ERROR} |] ==) -> True) where
  SQL_ERROR = ResIndicator [C.pure| SQLRETURN {SQL_ERROR} |]

pattern SQL_INVALID_HANDLE :: ResIndicator
pattern SQL_INVALID_HANDLE <- ((ResIndicator [C.pure| SQLRETURN {SQL_INVALID_HANDLE} |] ==) -> True) where
  SQL_INVALID_HANDLE = ResIndicator [C.pure| SQLRETURN {SQL_INVALID_HANDLE} |]

pattern SQL_STILL_EXECUTING :: ResIndicator
pattern SQL_STILL_EXECUTING <- ((ResIndicator [C.pure| SQLRETURN {SQL_STILL_EXECUTING} |] ==) -> True) where
  SQL_STILL_EXECUTING = ResIndicator [C.pure| SQLRETURN {SQL_STILL_EXECUTING} |]

pattern SQL_NEED_DATA :: ResIndicator
pattern SQL_NEED_DATA <- ((ResIndicator [C.pure| SQLRETURN {SQL_NEED_DATA} |] ==) -> True) where
  SQL_NEED_DATA = ResIndicator [C.pure| SQLRETURN {SQL_NEED_DATA} |]  

#if __GLASGOW_HASKELL__ >= 802
{-# COMPLETE
   SQL_NULL_DATA
 , SQL_NO_TOTAL
 , SQL_DATA_AT_EXEC
 , SQL_SUCCESS
 , SQL_SUCCESS_WITH_INFO
 , SQL_NO_DATA
 , SQL_ERROR
 , SQL_INVALID_HANDLE
 , SQL_STILL_EXECUTING
 , SQL_NEED_DATA
 :: ResIndicator
 #-}
#endif

newtype SQLType = SQLType C.CShort
  deriving (Eq, Storable)

instance Show SQLType where
  show = \case
    SQL_UNKNOWN_TYPE       -> "SQL_UNKNOWN_TYPE"
    SQL_CHAR               -> "SQL_CHAR"
    SQL_NUMERIC            -> "SQL_NUMERIC"
    SQL_DECIMAL            -> "SQL_DECIMAL"
    SQL_INTEGER            -> "SQL_INTEGER"
    SQL_SMALLINT           -> "SQL_SMALLINT"
    SQL_REAL               -> "SQL_REAL"
    SQL_FLOAT              -> "SQL_FLOAT"
    SQL_DOUBLE             -> "SQL_DOUBLE"
    SQL_DATETIME           -> "SQL_DATETIME"
    SQL_VARCHAR            -> "SQL_VARCHAR"
    SQL_DATE               -> "SQL_DATE"
    SQL_TYPE_DATE          -> "SQL_TYPE_DATE"
    SQL_INTERVAL           -> "SQL_INTERVAL"
    SQL_TIME               -> "SQL_TIME"
    SQL_TIMESTAMP          -> "SQL_TIMESTAMP"
    SQL_TYPE_TIMESTAMP     -> "SQL_TYPE_TIMESTAMP"
    SQL_LONGVARCHAR        -> "SQL_LONGVARCHAR"
    SQL_BINARY             -> "SQL_BINARY"
    SQL_VARBINARY          -> "SQL_VARBINARY"
    SQL_LONGVARBINARY      -> "SQL_LONGVARBINARY"
    SQL_BIGINT             -> "SQL_BIGINT"
    SQL_TINYINT            -> "SQL_TINYINT"
    SQL_BIT                -> "SQL_BIT"
    SQL_GUID               -> "SQL_GUID"
    SQL_WCHAR              -> "SQL_WCHAR"
    SQL_WVARCHAR           -> "SQL_WVARCHAR"
    SQL_WLONGVARCHAR       -> "SQL_WLONGVARCHAR"
    SQL_SS_TIME2           -> "SQL_SS_TIME2"
    SQL_SS_TIMESTAMPOFFSET -> "SQL_SS_TIMESTAMPOFFSET"
#if __GLASGOW_HASKELL__ < 802
    _                    -> error "Panic: impossible case"
#endif

pattern SQL_UNKNOWN_TYPE :: SQLType
pattern SQL_UNKNOWN_TYPE <- ((SQLType [C.pure| SQLSMALLINT {SQL_UNKNOWN_TYPE} |] ==) -> True) where
  SQL_UNKNOWN_TYPE = SQLType [C.pure| SQLSMALLINT {SQL_UNKNOWN_TYPE} |]

pattern SQL_CHAR :: SQLType
pattern SQL_CHAR <- ((SQLType [C.pure| SQLSMALLINT {SQL_CHAR} |] ==) -> True) where
  SQL_CHAR = SQLType [C.pure| SQLSMALLINT {SQL_CHAR} |]

pattern SQL_NUMERIC :: SQLType
pattern SQL_NUMERIC <- ((SQLType [C.pure| SQLSMALLINT {SQL_NUMERIC} |] ==) -> True) where
  SQL_NUMERIC = SQLType [C.pure| SQLSMALLINT {SQL_NUMERIC} |]

pattern SQL_DECIMAL :: SQLType
pattern SQL_DECIMAL <- ((SQLType [C.pure| SQLSMALLINT {SQL_DECIMAL} |] ==) -> True) where
  SQL_DECIMAL = SQLType [C.pure| SQLSMALLINT {SQL_DECIMAL} |]  

pattern SQL_INTEGER :: SQLType
pattern SQL_INTEGER <- ((SQLType [C.pure| SQLSMALLINT {SQL_INTEGER} |] ==) -> True) where
  SQL_INTEGER = SQLType [C.pure| SQLSMALLINT {SQL_INTEGER} |]

pattern SQL_SMALLINT :: SQLType
pattern SQL_SMALLINT <- ((SQLType [C.pure| SQLSMALLINT {SQL_SMALLINT} |] ==) -> True) where
  SQL_SMALLINT = SQLType [C.pure| SQLSMALLINT {SQL_SMALLINT} |]

pattern SQL_FLOAT :: SQLType
pattern SQL_FLOAT <- ((SQLType [C.pure| SQLSMALLINT {SQL_FLOAT} |] ==) -> True) where
  SQL_FLOAT = SQLType [C.pure| SQLSMALLINT {SQL_FLOAT} |]

pattern SQL_REAL :: SQLType
pattern SQL_REAL <- ((SQLType [C.pure| SQLSMALLINT {SQL_REAL} |] ==) -> True) where
  SQL_REAL = SQLType [C.pure| SQLSMALLINT {SQL_REAL} |]

pattern SQL_DOUBLE :: SQLType
pattern SQL_DOUBLE <- ((SQLType [C.pure| SQLSMALLINT {SQL_DOUBLE} |] ==) -> True) where
  SQL_DOUBLE = SQLType [C.pure| SQLSMALLINT {SQL_DOUBLE} |]

pattern SQL_DATETIME :: SQLType
pattern SQL_DATETIME <- ((SQLType [C.pure| SQLSMALLINT {SQL_DATETIME} |] ==) -> True) where
  SQL_DATETIME = SQLType [C.pure| SQLSMALLINT {SQL_DATETIME} |]

pattern SQL_VARCHAR :: SQLType
pattern SQL_VARCHAR <- ((SQLType [C.pure| SQLSMALLINT {SQL_VARCHAR} |] ==) -> True) where
  SQL_VARCHAR = SQLType [C.pure| SQLSMALLINT {SQL_VARCHAR} |]

pattern SQL_DATE :: SQLType
pattern SQL_DATE <- ((SQLType [C.pure| SQLSMALLINT {SQL_DATE} |] ==) -> True) where
  SQL_DATE = SQLType [C.pure| SQLSMALLINT {SQL_DATE} |]

pattern SQL_TYPE_DATE :: SQLType
pattern SQL_TYPE_DATE <- ((SQLType [C.pure| SQLSMALLINT {SQL_TYPE_DATE} |] ==) -> True) where
  SQL_TYPE_DATE = SQLType [C.pure| SQLSMALLINT {SQL_TYPE_DATE} |]  

pattern SQL_INTERVAL :: SQLType
pattern SQL_INTERVAL <- ((SQLType [C.pure| SQLSMALLINT {SQL_INTERVAL} |] ==) -> True) where
  SQL_INTERVAL = SQLType [C.pure| SQLSMALLINT {SQL_INTERVAL} |]

pattern SQL_TIME :: SQLType
pattern SQL_TIME <- ((SQLType [C.pure| SQLSMALLINT {SQL_TIME} |] ==) -> True) where
  SQL_TIME = SQLType [C.pure| SQLSMALLINT {SQL_TIME} |]

pattern SQL_TIMESTAMP :: SQLType
pattern SQL_TIMESTAMP <- ((SQLType [C.pure| SQLSMALLINT {SQL_TIMESTAMP} |] ==) -> True) where
  SQL_TIMESTAMP = SQLType [C.pure| SQLSMALLINT {SQL_TIMESTAMP} |]
  
pattern SQL_TYPE_TIMESTAMP :: SQLType
pattern SQL_TYPE_TIMESTAMP <- ((SQLType [C.pure| SQLSMALLINT {SQL_TYPE_TIMESTAMP} |] ==) -> True) where
  SQL_TYPE_TIMESTAMP = SQLType [C.pure| SQLSMALLINT {SQL_TYPE_TIMESTAMP} |]

pattern SQL_LONGVARCHAR :: SQLType
pattern SQL_LONGVARCHAR <- ((SQLType [C.pure| SQLSMALLINT {SQL_LONGVARCHAR} |] ==) -> True) where
  SQL_LONGVARCHAR = SQLType [C.pure| SQLSMALLINT {SQL_LONGVARCHAR} |]

pattern SQL_BINARY :: SQLType
pattern SQL_BINARY <- ((SQLType [C.pure| SQLSMALLINT {SQL_BINARY} |] ==) -> True) where
  SQL_BINARY = SQLType [C.pure| SQLSMALLINT {SQL_BINARY} |]

pattern SQL_VARBINARY :: SQLType
pattern SQL_VARBINARY <- ((SQLType [C.pure| SQLSMALLINT {SQL_VARBINARY} |] ==) -> True) where
  SQL_VARBINARY = SQLType [C.pure| SQLSMALLINT {SQL_VARBINARY} |]

pattern SQL_LONGVARBINARY :: SQLType
pattern SQL_LONGVARBINARY <- ((SQLType [C.pure| SQLSMALLINT {SQL_LONGVARBINARY} |] ==) -> True) where
  SQL_LONGVARBINARY = SQLType [C.pure| SQLSMALLINT {SQL_LONGVARBINARY} |]

pattern SQL_BIGINT :: SQLType
pattern SQL_BIGINT <- ((SQLType [C.pure| SQLSMALLINT {SQL_BIGINT} |] ==) -> True) where
  SQL_BIGINT = SQLType [C.pure| SQLSMALLINT {SQL_BIGINT} |]

pattern SQL_TINYINT :: SQLType
pattern SQL_TINYINT <- ((SQLType [C.pure| SQLSMALLINT {SQL_TINYINT} |] ==) -> True) where
  SQL_TINYINT = SQLType [C.pure| SQLSMALLINT {SQL_TINYINT} |]

pattern SQL_BIT :: SQLType
pattern SQL_BIT <- ((SQLType [C.pure| SQLSMALLINT {SQL_BIT} |] ==) -> True) where
  SQL_BIT = SQLType [C.pure| SQLSMALLINT {SQL_BIT} |]

pattern SQL_GUID :: SQLType
pattern SQL_GUID <- ((SQLType [C.pure| SQLSMALLINT {SQL_GUID} |] ==) -> True) where
  SQL_GUID = SQLType [C.pure| SQLSMALLINT {SQL_GUID} |]

pattern SQL_WCHAR :: SQLType
pattern SQL_WCHAR <- ((SQLType [C.pure| SQLSMALLINT {SQL_WCHAR} |] ==) -> True) where
  SQL_WCHAR = SQLType [C.pure| SQLSMALLINT {SQL_WCHAR} |]

pattern SQL_WVARCHAR :: SQLType
pattern SQL_WVARCHAR <- ((SQLType [C.pure| SQLSMALLINT {SQL_WVARCHAR} |] ==) -> True) where
  SQL_WVARCHAR = SQLType [C.pure| SQLSMALLINT {SQL_WVARCHAR} |]

pattern SQL_WLONGVARCHAR :: SQLType
pattern SQL_WLONGVARCHAR <- ((SQLType [C.pure| SQLSMALLINT {SQL_WLONGVARCHAR} |] ==) -> True) where
  SQL_WLONGVARCHAR = SQLType [C.pure| SQLSMALLINT {SQL_WLONGVARCHAR} |]

pattern SQL_SS_TIME2 :: SQLType
pattern SQL_SS_TIME2 <- ((SQLType [C.pure| SQLSMALLINT {SQL_SS_TIME2} |] ==) -> True) where
  SQL_SS_TIME2 = SQLType [C.pure| SQLSMALLINT {SQL_SS_TIME2} |]

pattern SQL_SS_TIMESTAMPOFFSET :: SQLType
pattern SQL_SS_TIMESTAMPOFFSET <- ((SQLType [C.pure| SQLSMALLINT {SQL_SS_TIMESTAMPOFFSET} |] ==) -> True) where
  SQL_SS_TIMESTAMPOFFSET = SQLType [C.pure| SQLSMALLINT {SQL_SS_TIMESTAMPOFFSET} |]  

#if __GLASGOW_HASKELL__ >= 802
{-# COMPLETE
   SQL_UNKNOWN_TYPE
 , SQL_CHAR
 , SQL_NUMERIC
 , SQL_DECIMAL
 , SQL_INTEGER
 , SQL_SMALLINT
 , SQL_FLOAT
 , SQL_REAL
 , SQL_DOUBLE
 , SQL_DATETIME
 , SQL_VARCHAR
 , SQL_DATE
 , SQL_INTERVAL
 , SQL_TIME
 , SQL_TIMESTAMP
 , SQL_LONGVARCHAR
 , SQL_BINARY
 , SQL_VARBINARY
 , SQL_LONGVARBINARY
 , SQL_BIGINT
 , SQL_TINYINT
 , SQL_BIT
 , SQL_GUID
 , SQL_WCHAR
 , SQL_WVARCHAR
 , SQL_WLONGVARCHAR

 , SQL_SS_TIME2
 , SQL_TYPE_DATE
 , SQL_SS_TIMESTAMPOFFSET
 :: SQLType
 #-}
#endif  

newtype HSCType = HSCType C.CInt
  deriving (Show, Read, Eq, Storable)

pattern SQL_C_CHAR :: HSCType
pattern SQL_C_CHAR <- ((HSCType [C.pure| int {SQL_C_CHAR} |] ==) -> True) where
  SQL_C_CHAR = HSCType [C.pure| int {SQL_C_CHAR} |]

pattern SQL_C_LONG :: HSCType
pattern SQL_C_LONG <- ((HSCType [C.pure| int {SQL_C_LONG} |] ==) -> True) where
  SQL_C_LONG = HSCType [C.pure| int {SQL_C_LONG} |]  

pattern SQL_C_SHORT :: HSCType
pattern SQL_C_SHORT <- ((HSCType [C.pure| int {SQL_C_SHORT} |] ==) -> True) where
  SQL_C_SHORT = HSCType [C.pure| int {SQL_C_SHORT} |]


pattern SQL_C_FLOAT :: HSCType
pattern SQL_C_FLOAT <- ((HSCType [C.pure| int {SQL_C_FLOAT} |] ==) -> True) where
  SQL_C_FLOAT = HSCType [C.pure| int {SQL_C_FLOAT} |]

pattern SQL_C_DOUBLE :: HSCType
pattern SQL_C_DOUBLE <- ((HSCType [C.pure| int {SQL_C_DOUBLE} |] ==) -> True) where
  SQL_C_DOUBLE = HSCType [C.pure| int {SQL_C_DOUBLE} |]

pattern SQL_C_NUMERIC :: HSCType
pattern SQL_C_NUMERIC <- ((HSCType [C.pure| int {SQL_C_NUMERIC} |] ==) -> True) where
  SQL_C_NUMERIC = HSCType [C.pure| int {SQL_C_NUMERIC} |]

pattern SQL_C_DEFAULT :: HSCType
pattern SQL_C_DEFAULT <- ((HSCType [C.pure| int {SQL_C_DEFAULT} |] ==) -> True) where
  SQL_C_DEFAULT = HSCType [C.pure| int {SQL_C_DEFAULT} |]

pattern SQL_C_DATE :: HSCType
pattern SQL_C_DATE <- ((HSCType [C.pure| int {SQL_C_DATE} |] ==) -> True) where
  SQL_C_DATE = HSCType [C.pure| int {SQL_C_DATE} |]

pattern SQL_C_TIME :: HSCType
pattern SQL_C_TIME <- ((HSCType [C.pure| int {SQL_C_TIME} |] ==) -> True) where
  SQL_C_TIME = HSCType [C.pure| int {SQL_C_TIME} |]

pattern SQL_C_TIMESTAMP :: HSCType
pattern SQL_C_TIMESTAMP <- ((HSCType [C.pure| int {SQL_C_TIMESTAMP} |] ==) -> True) where
  SQL_C_TIMESTAMP = HSCType [C.pure| int {SQL_C_TIMESTAMP} |]

pattern SQL_C_WCHAR :: HSCType
pattern SQL_C_WCHAR <- ((HSCType [C.pure| int {SQL_C_WCHAR} |] ==) -> True) where
  SQL_C_WCHAR = HSCType [C.pure| int {SQL_C_WCHAR} |]  

#if __GLASGOW_HASKELL__ >= 802
{-# COMPLETE
   SQL_C_CHAR
 , SQL_C_LONG
 , SQL_C_SHORT
 , SQL_C_FLOAT
 , SQL_C_DOUBLE
 , SQL_C_NUMERIC
 , SQL_C_DEFAULT
 , SQL_C_DATE
 , SQL_C_TIME
 , SQL_C_TIMESTAMP
 , SQL_C_WCHAR
 :: HSCType
 #-}
#endif

newtype HandleType = HandleType C.CInt
  deriving (Show, Read, Eq, Storable)

pattern SQL_HANDLE_ENV :: HandleType
pattern SQL_HANDLE_ENV <- ((HandleType [C.pure| int {SQL_HANDLE_ENV} |] ==) -> True) where
  SQL_HANDLE_ENV = HandleType [C.pure| int {SQL_HANDLE_ENV} |]

pattern SQL_HANDLE_DBC :: HandleType
pattern SQL_HANDLE_DBC <- ((HandleType [C.pure| int {SQL_HANDLE_DBC} |] ==) -> True) where
  SQL_HANDLE_DBC = HandleType [C.pure| int {SQL_HANDLE_DBC} |]

pattern SQL_HANDLE_STMT :: HandleType
pattern SQL_HANDLE_STMT <- ((HandleType [C.pure| int {SQL_HANDLE_STMT} |] ==) -> True) where
  SQL_HANDLE_STMT = HandleType [C.pure| int {SQL_HANDLE_STMT} |]

pattern SQL_HANDLE_DESC :: HandleType
pattern SQL_HANDLE_DESC <- ((HandleType [C.pure| int {SQL_HANDLE_DESC} |] ==) -> True) where
  SQL_HANDLE_DESC = HandleType [C.pure| int {SQL_HANDLE_DESC} |]

#if __GLASGOW_HASKELL__ >= 802
{-# COMPLETE
   SQL_HANDLE_ENV
 , SQL_HANDLE_DBC
 , SQL_HANDLE_STMT
 , SQL_HANDLE_DESC
 :: HandleType
 #-}
#endif

newtype NullableFieldDesc = NullableFieldDesc C.CShort
  deriving (Show, Read, Eq, Storable)

pattern SQL_NO_NULLS :: NullableFieldDesc
pattern SQL_NO_NULLS <- ((NullableFieldDesc [C.pure| SQLSMALLINT {SQL_NO_NULLS} |] ==) -> True) where
  SQL_NO_NULLS = NullableFieldDesc [C.pure| SQLSMALLINT {SQL_NO_NULLS} |]

pattern SQL_NULLABLE :: NullableFieldDesc
pattern SQL_NULLABLE <- ((NullableFieldDesc [C.pure| SQLSMALLINT {SQL_NULLABLE} |] ==) -> True) where
  SQL_NULLABLE = NullableFieldDesc [C.pure| SQLSMALLINT {SQL_NULLABLE} |]

pattern SQL_NULLABLE_UNKNOWN :: NullableFieldDesc
pattern SQL_NULLABLE_UNKNOWN <- ((NullableFieldDesc [C.pure| SQLSMALLINT {SQL_NULLABLE_UNKNOWN} |] ==) -> True) where
  SQL_NULLABLE_UNKNOWN = NullableFieldDesc [C.pure| SQLSMALLINT {SQL_NULLABLE_UNKNOWN} |]

#if __GLASGOW_HASKELL__ >= 820
{-# COMPLETE
   SQL_NO_NULLS
 , SQL_NULLABLE
 , SQL_NULLABLE_UNKNOWN
 :: NullableFieldDesc
 #-}  
#endif

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) f = getCompose . fmap f . Compose

(<**>) :: ( Applicative f
         , Applicative g
         ) => f (g (a -> b)) -> f (g a) -> f (g b)
(<**>) f = getCompose . liftA2 id (Compose f) . Compose

newtype Money = Money { getMoney :: Scientific }
              deriving (Eq)

instance Show Money where
  show (Money s) =
    formatScientific Fixed (Just 4) s

newtype SmallMoney = SmallMoney { getSmallMoney :: Scientific }
                   deriving (Eq)

instance Show SmallMoney where
  show (SmallMoney s) =
    formatScientific Fixed (Just 4) s

newtype Image = Image { getImage :: LBS.ByteString }
              deriving (Eq, Show)

sqlMapping :: HM.HashMap TypeRep [SQLType]
sqlMapping =
  HM.fromList
  [ (typeOf (undefined :: CChar)     , [SQL_VARCHAR, SQL_LONGVARCHAR, SQL_CHAR, SQL_DECIMAL, SQL_LONGVARCHAR, SQL_WLONGVARCHAR, SQL_WVARCHAR])
  , (typeOf (undefined :: CUChar)    , [SQL_VARCHAR, SQL_LONGVARCHAR, SQL_CHAR])
  , (typeOf (undefined :: CWchar)    , [SQL_VARCHAR, SQL_LONGVARCHAR, SQL_CHAR, SQL_LONGVARCHAR, SQL_WLONGVARCHAR, SQL_WVARCHAR])
  , (typeOf (undefined :: CBinary)   , [SQL_LONGVARBINARY, SQL_VARBINARY, SQL_WLONGVARCHAR, SQL_VARCHAR, SQL_WVARCHAR, SQL_LONGVARCHAR])  
  , (typeOf (undefined :: CUTinyInt) , [SQL_TINYINT])
  , (typeOf (undefined :: CTinyInt)  , [SQL_TINYINT])
  , (typeOf (undefined :: CLong)     , [SQL_INTEGER])
  , (typeOf (undefined :: CULong)    , [SQL_INTEGER])
  , (typeOf (undefined :: CSmallInt) , [SQL_SMALLINT])
  , (typeOf (undefined :: CUSmallInt), [SQL_SMALLINT])
  , (typeOf (undefined :: CFloat)    , [SQL_REAL, SQL_DECIMAL])
  , (typeOf (undefined :: CDouble)   , [SQL_FLOAT, SQL_DECIMAL])
  , (typeOf (undefined :: CBool)     , [SQL_BIT])
  , (typeOf (undefined :: CDate)     , [SQL_DATE, SQL_TYPE_DATE])
  , (typeOf (undefined :: CBigInt)   , [SQL_BIGINT])
  , (typeOf (undefined :: CUBigInt)  , [SQL_BIGINT])
  , (typeOf (undefined :: CTimeOfDay), [SQL_TIME, SQL_SS_TIME2])
  , (typeOf (undefined :: CLocalTime), [SQL_TIMESTAMP, SQL_TYPE_TIMESTAMP])
  , (typeOf (undefined :: CZonedTime), [SQL_SS_TIMESTAMPOFFSET])
  , (typeOf (undefined :: UUID)      , [SQL_GUID])
  ]

returnWithRetCode :: ResIndicator -> HandleRef -> a -> IO a
returnWithRetCode ret ref a =
  case isSuccessful ret of
    True  -> pure a
    False -> getErrors ret ref >>= throwSQLException

{-

- segfault issue
- right associativeness of <>
- sized variants
- extractWith errors
- constraint checks in Database instance turned off. turn it back on
- CheckCT not necessary to be captured


-}