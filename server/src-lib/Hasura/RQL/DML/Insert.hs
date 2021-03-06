module Hasura.RQL.DML.Insert
 ( runInsert
 ) where

import           Hasura.Prelude

import qualified Data.HashMap.Strict                          as HM
import qualified Data.HashSet                                 as HS
import qualified Data.Sequence                                as DS
import qualified Database.PG.Query                            as Q

import           Data.Aeson.Types
import           Data.Text.Extended
import           Instances.TH.Lift                            ()

import qualified Hasura.Backends.Postgres.SQL.DML             as S

import           Hasura.Backends.Postgres.Connection
import           Hasura.Backends.Postgres.Execute.Mutation
import           Hasura.Backends.Postgres.SQL.Types
import           Hasura.Backends.Postgres.Translate.Insert
import           Hasura.Backends.Postgres.Translate.Returning
import           Hasura.EncJSON
import           Hasura.RQL.DML.Internal
import           Hasura.RQL.IR.Insert
import           Hasura.RQL.Types
import           Hasura.Server.Version                        (HasVersion)
import           Hasura.Session


import qualified Data.Environment                             as Env
import qualified Hasura.Tracing                               as Tracing

convObj
  :: (UserInfoM m, QErrM m)
  => (ColumnType 'Postgres -> Value -> m S.SQLExp)
  -> HM.HashMap PGCol S.SQLExp
  -> HM.HashMap PGCol S.SQLExp
  -> FieldInfoMap (FieldInfo 'Postgres)
  -> InsObj
  -> m ([PGCol], [S.SQLExp])
convObj prepFn defInsVals setInsVals fieldInfoMap insObj = do
  inpInsVals <- flip HM.traverseWithKey insObj $ \c val -> do
    let relWhenPGErr = "relationships can't be inserted"
    colType <- askPGType fieldInfoMap c relWhenPGErr
    -- if column has predefined value then throw error
    when (c `elem` preSetCols) $ throwNotInsErr c
    -- Encode aeson's value into prepared value
    withPathK (getPGColTxt c) $ prepFn colType val
  let insVals = HM.union setInsVals inpInsVals
      sqlExps = HM.elems $ HM.union insVals defInsVals
      inpCols = HM.keys inpInsVals

  return (inpCols, sqlExps)
  where
    preSetCols = HM.keys setInsVals

    throwNotInsErr c = do
      roleName <- _uiRole <$> askUserInfo
      throw400 NotSupported $ "column " <> c <<> " is not insertable"
        <> " for role " <>> roleName


convInsertQuery
  :: (UserInfoM m, QErrM m, CacheRM m)
  => (Value -> m [InsObj])
  -> SessVarBldr 'Postgres m
  -> (ColumnType 'Postgres -> Value -> m S.SQLExp)
  -> InsertQuery
  -> m (InsertQueryP1 'Postgres)
convInsertQuery objsParser sessVarBldr prepFn (InsertQuery tableName val oC mRetCols) = do

  insObjs <- objsParser val

  -- Get the current table information
  tableInfo <- askTabInfo tableName
  let coreInfo = _tiCoreInfo tableInfo

  -- If table is view then check if it is insertable
  mutableView tableName viIsInsertable
    (_tciViewInfo coreInfo) "insertable"

  -- Check if the role has insert permissions
  insPerm   <- askInsPermInfo tableInfo
  updPerm   <- askPermInfo' PAUpdate tableInfo

  -- Check if all dependent headers are present
  validateHeaders $ ipiRequiredHeaders insPerm

  let fieldInfoMap = _tciFieldInfoMap coreInfo
      setInsVals = ipiSet insPerm

  -- convert the returning cols into sql returing exp
  mAnnRetCols <- forM mRetCols $ \retCols -> do
    -- Check if select is allowed only if you specify returning
    selPerm <- modifyErr (<> selNecessaryMsg) $
               askSelPermInfo tableInfo

    withPathK "returning" $ checkRetCols fieldInfoMap selPerm retCols

  let mutOutput = mkDefaultMutFlds mAnnRetCols

  let defInsVals = S.mkColDefValMap $
                   map pgiColumn $ getCols fieldInfoMap
      allCols    = getCols fieldInfoMap
      insCols    = HM.keys defInsVals

  resolvedPreSet <- mapM (convPartialSQLExp sessVarBldr) setInsVals

  insTuples <- withPathK "objects" $ indexedForM insObjs $ \obj ->
    convObj prepFn defInsVals resolvedPreSet fieldInfoMap obj
  let sqlExps = map snd insTuples
      inpCols = HS.toList $ HS.fromList $ concatMap fst insTuples

  insCheck <- convAnnBoolExpPartialSQL sessVarFromCurrentSetting (ipiCheck insPerm)
  updCheck <- traverse (convAnnBoolExpPartialSQL sessVarFromCurrentSetting) (upiCheck =<< updPerm)

  conflictClause <- withPathK "on_conflict" $ forM oC $ \c -> do
      roleName <- askCurRole
      unless (isTabUpdatable roleName tableInfo) $ throw400 PermissionDenied $
        "upsert is not allowed for role " <> roleName
        <<> " since update permissions are not defined"

      buildConflictClause sessVarBldr tableInfo inpCols c
  return $ InsertQueryP1 tableName insCols sqlExps
           conflictClause (insCheck, updCheck) mutOutput allCols
  where
    selNecessaryMsg =
      "; \"returning\" can only be used if the role has "
      <> "\"select\" permission on the table"

convInsQ
  :: (QErrM m, UserInfoM m, CacheRM m)
  => InsertQuery
  -> m (InsertQueryP1 'Postgres, DS.Seq Q.PrepArg)
convInsQ =
  runDMLP1T .
  convInsertQuery (withPathK "objects" . decodeInsObjs)
  sessVarFromCurrentSetting
  binRHSBuilder

runInsert
  :: ( HasVersion, QErrM m, UserInfoM m
     , CacheRM m, MonadTx m, HasSQLGenCtx m, MonadIO m
     , Tracing.MonadTrace m
     )
  => Env.Environment -> InsertQuery -> m EncJSON
runInsert env q = do
  res <- convInsQ q
  strfyNum <- stringifyNum <$> askSQLGenCtx
  execInsertQuery env strfyNum Nothing res

decodeInsObjs :: (UserInfoM m, QErrM m) => Value -> m [InsObj]
decodeInsObjs v = do
  objs <- decodeValue v
  when (null objs) $ throw400 UnexpectedPayload "objects should not be empty"
  return objs
