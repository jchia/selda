{-# LANGUAGE TypeOperators, OverloadedStrings, CPP, DeriveGeneric #-}
module Main where
import Control.Monad
import Control.Monad.Catch
import Data.List hiding (groupBy, insert)
import Data.Text (Text)
import System.Directory
import System.Exit
import Test.HUnit
import Test.HUnit.Text
import Database.Selda
import Database.Selda.Backend
import Database.Selda.Generic
import Data.Time
import Control.Concurrent

#ifdef POSTGRES
-- To test the PostgreSQL backend, specify the connection info for the server
-- as PGConnectInfo.pgConnectInfo :: PGConnectInfo.
import Database.Selda.PostgreSQL
import PGConnectInfo (pgConnectInfo)
#else
import Database.Selda.SQLite
#endif

data Person = Person
  { name :: Text
  , age  :: Int
  , pet  :: Maybe Text
  , cash :: Double
  } deriving (Generic, Show, Ord, Eq)

genPeople :: GenTable Person
genPeople = genTable "genpeople" [name :- primaryGen]

people :: Table (Text :*: Int :*: Maybe Text :*: Double)
people =
      table "people"
  $   primary "name"
  :*: required "age"
  :*: optional "pet"
  :*: required "cash"
pName :*: pAge :*: pPet :*: pCash = selectors people

addresses :: Table (Text :*: Text)
(addresses, aName :*: aCity) =
      tableWithSelectors "addresses"
  $   required "name"
  :*: required "city"

comments :: Table (Int :*: Maybe Text :*: Text)
comments =
      table "comments"
  $   autoPrimary "id"
  :*: optional "author"
  :*: required "comment"
cId :*: cName :*: cComment = selectors comments

times :: Table (Text :*: UTCTime :*: Day :*: TimeOfDay)
times =
      table "times"
  $   required "description"
  :*: required "time"
  :*: required "day"
  :*: required "local_tod"

genPeopleItems =
  [ Person "Link"      125 (Just "horse")  13506
  , Person "Velvet"     19 Nothing         5.55
  , Person "Kobayashi"  23 (Just "dragon") 103707.55
  , Person "Miyu"       10 Nothing         (-500)
  ]

peopleItems =
  [ "Link"      :*: 125 :*: Just "horse"  :*: 13506
  , "Velvet"    :*: 19  :*: Nothing       :*: 5.55
  , "Kobayashi" :*: 23  :*: Just "dragon" :*: 103707.55
  , "Miyu"      :*: 10  :*: Nothing       :*: (-500)
  ]

addressItems =
  [ "Link"      :*: "Kakariko"
  , "Kobayashi" :*: "Tokyo"
  , "Miyu"      :*: "Fuyukishi"
  ]

commentItems =
  [ Just "Link" :*: "Well, excuuuse me, princess!"
  , Nothing     :*: "Anonymous spam comment"
  ]

setup :: SeldaT IO ()
setup = do
  createTable (gen genPeople)
  createTable people
  createTable addresses
  createTable comments
  createTable times
  insert_ (gen genPeople) peopleItems
  insert_ people peopleItems
  insert_ addresses addressItems
  insert_ comments (map (def :*:) commentItems)

teardown :: SeldaT IO ()
teardown = do
  tryDropTable (gen genPeople)
  tryDropTable people
  tryDropTable addresses
  tryDropTable comments
  tryDropTable times

main = do
  tmpdir <- getTemporaryDirectory
  let dbfile = tmpdir ++ "/" ++ "__selda_test_tmp.sqlite"
  freshEnv dbfile $ teardown
  result <- runTestTT (allTests dbfile)
  case result of
    Counts cs tries 0 0 -> return ()
    _                   -> exitFailure

-- | Run the given computation over the given SQLite file. If the file exists,
--   it will be removed first.
freshEnv :: FilePath -> SeldaT IO a -> IO a
#ifdef POSTGRES
freshEnv _ m = withPostgreSQL pgConnectInfo $ teardown >> m
#else
freshEnv file m = do
  exists <- doesFileExist file
  when exists $ removeFile file
  x <- withSQLite file m
  removeFile file
  return x
#endif

-- | Assert that the given computation should fail.
assertFail :: SeldaT IO a -> SeldaT IO ()
assertFail m = do
  res <- try m
  case res of
    Left (SomeException _) -> return ()
    _                      -> liftIO $ assertFailure "computation did not fail"

-- | @SeldaT@ wrapper for 'assertEqual'.
assEq :: (Show a, Eq a) => String -> a -> a -> SeldaT IO ()
assEq s expect actual = liftIO $ assertEqual s expect actual

-- | @SeldaT@ wrapper for 'assertBool'.
ass :: String -> Bool -> SeldaT IO ()
ass s pred = liftIO $ assertBool s pred

allTests f = TestList
  [ "non-database tests"       ~: noDBTests
  , "query tests"              ~: queryTests run
  , "mutable tests"            ~: freshEnvTests (freshEnv f)
  , "mutable tests (caching)"  ~: freshEnvTests caching
  , "cache + transaction race" ~: invalidateCacheAfterTransaction run
  ]
  where
    caching m = freshEnv f (setLocalCache 1000 >> m)
#ifdef POSTGRES
    run = withPostgreSQL pgConnectInfo
#else
    run = withSQLite f
#endif


-- Tests that don't even touch the database
noDBTests = test
  [ "id == fromRel . toRel" ~: fromRelToRelId
  ]

fromRelToRelId =
    assertEqual "fromRel . toRel /= id" genPeopleItems xs
  where
    xs = map (fromRel . toRel) genPeopleItems

-- Tests that don't mutate the database

queryTests run = test
  [ "setup succeeds" ~: run setup
  , "simple select" ~: run simpleSelect
  , "simple product"  ~: run simpleProduct
  , "order ascending"  ~: run orderAscending
  , "filter equal"  ~: run filterEqual
  , "filter not equal"  ~: run filterNotEqual
  , "join-like product" ~: run joinLikeProduct
  , "simple left join" ~: run simpleLeftJoin
  , "left join followed by product" ~: run leftJoinThenProduct
  , "count aggregation" ~: run countAggregate
  , "aggregate with join and group" ~: run joinGroupAggregate
  , "nested left join" ~: run nestedLeftJoin
  , "order + limit" ~: run orderLimit
  , "limit gives correct number of results" ~: run limitCorrectNumber
  , "aggregate with doubles" ~: run aggregateWithDoubles
  , "generic query on ad hoc table" ~: run genQueryAdHocTable
  , "generic query on generic table" ~: run genQueryGenTable
  , "ad hoc query on generic table" ~: run adHocQueryGenTable
  , "select from value table" ~: run selectVals
  , "select from empty value table" ~: run selectEmptyValues
  , "aggregate from empty value table" ~: run aggregateEmptyValues
  , "teardown succeeds" ~: run teardown
  ]

simpleSelect = do
  ppl <- query $ select people
  assEq "wrong results from select" (sort peopleItems) (sort ppl)

simpleProduct = do
  prod <- query $ do
    name :*: city <- select addresses
    person <- select people
    return (name :*: city :*: person)
  assEq "wrong results from product" (sort ans) (sort prod)
  where
    ans = [n :*: c :*: p | p <- peopleItems, (n :*: c) <- addressItems]

orderAscending = do
  ppl <- query $ do
    name :*: rest <- select people
    order name ascending
    return (name :*: rest)
  assEq "result not properly sorted" (sort peopleItems) ppl

filterEqual = do
  ppl <- query $ do
    name :*: rest <- select people
    restrict (name .== "Link")
    return name
  assEq "unequal elements not removed" ["Link"] ppl

filterNotEqual = do
  ppl <- query $ do
    name :*: rest <- select people
    restrict (name ./= "Link")
    return name
  ass "filtered element still in list" (not $ "Link" `elem` ppl)

joinLikeProduct = do
  res <- query $ do
    name :*: rest <- select people
    name' :*: city <- select addresses
    restrict (name .== name')
    return (name :*: city)
  assEq "join-like query gave wrong result" (sort ans) (sort res)
  where
    ans = [n :*: c | n :*: _ <- peopleItems, n' :*: c <- addressItems, n == n']

joinLikeProductWithSels = do
  res <- query $ do
    p <- select people
    a <- select addresses
    restrict (p ! pName .== a ! aName)
    return (p ! pName :*: a ! aCity :*: p ! pPet)
  assEq "join-like query gave wrong result" (sort ans) (sort res)
  where
    ans =
      [ n :*: c :*: p
      | n :*: _ :*: p :*: _ <- peopleItems
      , n' :*: c <- addressItems
      , n == n'
      ]

simpleLeftJoin = do
  res <- query $ do
    name :*: rest <- select people
    _ :*: city <- leftJoin (\(name' :*: _) -> name .== name')
                           (select addresses)
    return (name :*: city)
  assEq "join-like query gave wrong result" (sort ans) (sort res)
  where
    ans =
      [ "Link"      :*: Just "Kakariko"
      , "Velvet"    :*: Nothing
      , "Miyu"      :*: Just "Fuyukishi"
      , "Kobayashi" :*: Just "Tokyo"
      ]

leftJoinThenProduct = do
  res <- query $ do
    name :*: rest <- select people
    _ :*: city <- leftJoin (\(name' :*: _) -> name .== name')
                           (select addresses)
    _ :*: name' :*: c <- select comments
    restrict (name' .== just name)
    return (name :*: city :*: c)
  assEq "join + product gave wrong result" ans res
  where
    linkComment = head [c | n :*: c <- commentItems, n == Just "Link"]
    ans = ["Link" :*: Just "Kakariko" :*: linkComment]

countAggregate = do
  [res] <- query . aggregate $ do
    _ :*: _ :*: pet :*: _ <- select people
    return (count pet)
  assEq "count counted the wrong number of pets" ans res
  where
    ans = length [pet | _ :*: _ :*: Just pet :*: _ <- peopleItems]

joinGroupAggregate = do
  res <- query . aggregate $ do
    name :*: _ :*: pet :*: _ <- select people
    _ :*: city <- leftJoin (\(name' :*: _) -> name .== name')
                           (select addresses)
    nopet <- groupBy (isNull pet)
    return (nopet :*: count city)
  assEq "wrong number of cities per pet owneship status" ans (sort res)
  where
    -- There are pet owners in Tokyo and Kakariko, there is no pet owner in
    -- Fuyukishi
    ans = [False :*: 2, True :*: 1]

nestedLeftJoin = do
  res <- query $ do
    name :*: _ :*: pet :*: _ <- select people
    _ :*: city :*: cs <- leftJoin (\(name' :*: _) -> name .== name') $ do
      name' :*: city <- select addresses
      _ :*: cs <- leftJoin (\(n :*: _) -> n .== just name') $ aggregate $ do
        _ :*: name' :*: comment <- select comments
        n <- groupBy name'
        return (n :*: count comment)
      return (name' :*: city :*: cs)
    return (name :*: city :*: cs)
  ass ("user with comment not in result: " ++ show res) (link `elem` res)
  ass ("user without comment not in result: " ++ show res) (velvet `elem` res)
  where
    link = "Link" :*: Just "Kakariko" :*: Just (1 :: Int)
    velvet = "Velvet" :*: Nothing :*: Nothing

orderLimit = do
  res <- query $ limit 1 2 $ do
    name :*: age :*: pet :*: cash <- select people
    order cash descending
    return name
  assEq "got wrong result" ["Link", "Velvet"] (sort res)

limitCorrectNumber = do
  res <- query $ do
    p1 <- limit 1 2 $ select people
    p2 <- limit 1 2 $ select people
    return p1
  assEq ("wrong number of results from limit") 4 (length res)

aggregateWithDoubles = do
  [res] <- query $ aggregate $ do
    name :*: age :*: pet :*: cash <- select people
    return (avg cash)
  assEq "got wrong result" ans res
  where
    ans = sum (map fourth peopleItems)/fromIntegral (length peopleItems)

genQueryAdHocTable = do
  ppl <- map fromRel <$> query (select people)
  assEq "wrong results from fromRel" (sort genPeopleItems) (sort ppl)

genQueryGenTable = do
    ppl1 <- query $ do
      person <- select $ gen genPeople
      restrict (person ! pCash .> 0)
      return (person ! pName :*: person ! pAge)
    assEq "query gave wrong result" (sort ppl2) (sort ppl1)
  where
    ppl2 = [name p :*: age p | p <- genPeopleItems, cash p > 0]

q :: Query () (Col () Text :*: Col () Int)
q = do
      person <- select $ gen genPeople
      restrict (person ! pCash .> 0)
      return (person ! pName :*: person ! pAge)

adHocQueryGenTable = do
    ppl1 <- query $ do
      name :*: age :*: pet :*: cash <- select $ gen genPeople
      restrict (cash .> 0)
      return (name :*: age)
    assEq "query gave wrong result" (sort ppl2) (sort ppl1)
  where
    ppl2 = [name p :*: age p | p <- genPeopleItems, cash p > 0]

selectVals = do
  vals <- query $ selectValues peopleItems
  assEq "wrong columns returned" (sort peopleItems) (sort vals)

selectEmptyValues = do
  res <- query $ do
    ppl <- select people
    vals <- selectValues ([] :: [Maybe Text])
    cs <- select comments
    return cs
  assEq "result set wasn't empty" [] res

aggregateEmptyValues = do
  [res] <- query $ aggregate $ do
    ppl <- select people
    vals <- selectValues ([] :: [Int :*: Int])
    id :*: _ <- select comments
    return (count id)
  assEq "wrong count for empty result set" 0 res

-- Tests that mutate the database

freshEnvTests freshEnv = test
  [ "tryDrop never fails"            ~: freshEnv tryDropNeverFails
  , "tryCreate never fails"          ~: freshEnv tryCreateNeverFails
  , "drop fails on missing"          ~: freshEnv dropFailsOnMissing
  , "create fails on duplicate"      ~: freshEnv createFailsOnDuplicate
  , "auto primary increments"        ~: freshEnv autoPrimaryIncrements
  , "insert returns number of rows"  ~: freshEnv insertReturnsNumRows
  , "update updates table"           ~: freshEnv updateUpdates
  , "update nothing"                 ~: freshEnv updateNothing
  , "insert time values"             ~: freshEnv insertTime
  , "transaction completes"          ~: freshEnv transactionCompletes
  , "transaction rolls back"         ~: freshEnv transactionRollsBack
  , "queries are consistent"         ~: freshEnv consistentQueries
  , "delete deletes"                 ~: freshEnv deleteDeletes
  , "generic delete"                 ~: freshEnv genericDelete
  , "generic update"                 ~: freshEnv genericUpdate
  , "generic insert"                 ~: freshEnv genericInsert
  , "ad hoc insert in generic table" ~: freshEnv adHocInsertInGenericTable
  , "delete everything"              ~: freshEnv deleteEverything
  , "override auto-increment"        ~: freshEnv overrideAutoIncrement
  , "insert all defaults"            ~: freshEnv insertAllDefaults
  , "insert some defaults"           ~: freshEnv insertSomeDefaults
  , "quoted weird names"             ~: freshEnv weirdNames
  , "nul identifiers fail"           ~: freshEnv nulIdentifiersFail
  , "empty identifiers are caught"   ~: freshEnv emptyIdentifiersFail
  , "duplicate columns are caught"   ~: freshEnv duplicateColsFail
  , "duplicate PKs are caught"       ~: freshEnv duplicatePKsFail
  , "dupe insert throws SeldaError"  ~: freshEnv dupeInsertThrowsSeldaError
  , "dupe insert 2 throws SeldaError"~: freshEnv dupeInsert2ThrowsSeldaError
  , "dupe update throws SeldaError"  ~: freshEnv dupeUpdateThrowsSeldaError
  , "duplicate PKs are caught"       ~: freshEnv duplicatePKsFail
  , "nul queries don't fail"         ~: freshEnv nulQueries
  ]

tryDropNeverFails = teardown
tryCreateNeverFails = tryCreateTable comments >> tryCreateTable comments
dropFailsOnMissing = assertFail $ dropTable comments
createFailsOnDuplicate = createTable people >> assertFail (createTable people)

autoPrimaryIncrements = do
  setup
  k <- insertWithPK comments [def :*: Just "Kobayashi" :*: "チョロゴン" ]
  k' <- insertWithPK comments [def :*: Nothing :*: "more anonymous spam"]
  [name] <- query $ do
    id :*: name :*: _ <- select comments
    restrict (id .== int k)
    return name
  assEq "inserted key refers to wrong value" name (Just "Kobayashi")
  ass "primary key doesn't increment properly" (k' == k+1)

insertReturnsNumRows = do
  setup
  rows <- insert comments
    [ def :*: Just "Kobayashi" :*: "チョロゴン"
    , def :*: Nothing :*: "more anonymous spam"
    , def :*: Nothing :*: "even more spam"
    ]
  assEq "insert returns wrong number of inserted rows" 3 rows

updateUpdates = do
  setup
  insert_ comments
    [ def :*: Just "Kobayashi" :*: "チョロゴン"
    , def :*: Nothing :*: "more anonymous spam"
    , def :*: Nothing :*: "even more spam"
    ]
  rows <- update comments (isNull . second)
                          (\(id :*: _ :*: c) -> (id :*: just "anon" :*: c))
  [upd] <- query $ aggregate $ do
    _ :*: name :*: _ <- select comments
    restrict (not_ $ isNull name)
    restrict (name .== just "anon")
    return (count name)
  assEq "update returns wrong number of updated rows" 3 rows
  assEq "rows were not updated" 3 upd

updateNothing = do
  setup
  a <- query $ select people
  n <- update people (const true) id
  b <- query $ select people
  assEq "identity update didn't happen" (length a) n
  assEq "identity update did something weird" a b

insertTime = do
  setup
  let Just t = parseTimeM True defaultTimeLocale sqlDateTimeFormat "2011-11-11 11:11:11.11111"
      Just d = parseTimeM True defaultTimeLocale sqlDateFormat "2011-11-11"
      Just lt = parseTimeM True defaultTimeLocale sqlTimeFormat "11:11:11.11111"
  insert_ times ["now" :*: t :*: d :*: lt]
  ["now" :*: t' :*: d' :*: lt'] <- query $ select times
  assEq "time not properly inserted" (t, d, lt) (t', d', lt')

transactionCompletes = do
  setup
  transaction $ do
    insert_ comments [def :*: Just "Kobayashi" :*: c1]
    insert_ comments
      [ def :*: Nothing :*: "more anonymous spam"
      , def :*: Just "Kobayashi" :*: c2
      ]
  cs <- query $ do
    _ :*: name :*: comment <- select comments
    restrict (name .== just "Kobayashi")
    return comment
  ass "some inserts were not performed"
      (c1 `elem` cs && c2 `elem` cs && length cs == 2)
  where
    c1 = "チョロゴン"
    c2 = "メイド最高！"

transactionRollsBack = do
  setup
  res <- try $ transaction $ do
    insert_ comments [def :*: Just "Kobayashi" :*: c1]
    insert_ comments
      [ def :*: Nothing :*: "more anonymous spam"
      , def :*: Just "Kobayashi" :*: c2
      ]
    fail "nope"
  case res of
    Right _ ->
      liftIO $ assertFailure "exception didn't propagate"
    Left (SomeException _) -> do
      cs <- query $ do
        _ :*: name :*: comment <- select comments
        restrict (name .== just "Kobayashi")
        return comment
      assEq "commit was not rolled back" [] cs
  where
    c1 = "チョロゴン"
    c2 = "メイド最高！"

consistentQueries = do
  setup
  a <- query q
  b <- query q
  assEq "query result changed on its own" a b
  where
    q = do
      (name :*: age :*: _ :*: cash) <- select people
      restrict (round_ cash .> age)
      return name

deleteDeletes = do
  setup
  a <- query q
  deleteFrom_ people (\(name :*: _) -> name .== "Link")
  b <- query q
  ass "rows not deleted" (a /= b && length b < length a)
  where
    q = do
      (name :*: age :*: _ :*: cash) <- select people
      restrict (round_ cash .> age)
      return name

deleteEverything = do
  setup
  a <- query q
  deleteFrom_ people (const true)
  b <- query q
  ass "table empty before delete" (a /= [])
  assEq "rows not deleted" [] b
  where
    q = do
      (name :*: age :*: _ :*: cash) <- select people
      restrict (round_ cash .> age)
      return name

genericDelete = do
  setup
  deleteFrom_ (gen genPeople) (\p -> p ! pCash .> 0)
  monies <- query $ do
    p <- select (gen genPeople)
    return (p ! pCash)
  ass "deleted wrong items" $ all (<= 0) monies

genericUpdate = do
  setup
  update_ (gen genPeople) (\p -> p ! pCash .> 0)
                          (\p -> p `with` [pCash := 0])
  monies <- query $ do
    p <- select (gen genPeople)
    return (p ! pCash)
  ass "update failed" $ all (<= 0) monies

genericInsert = do
  setup
  q1 <- query $ select (gen genPeople)
  deleteFrom_ (gen genPeople) (const true)
  insertGen_ genPeople genPeopleItems
  q2 <- query $ select (gen genPeople)
  assEq "insert failed" (sort q1) (sort q2)

adHocInsertInGenericTable = do
  setup
  insert_ (gen genPeople) [val]
  [val'] <- query $ do
    p <- select (gen genPeople)
    restrict (p ! pName .== "Saber")
    return p
  assEq "insert failed" val val'
  where
    val = "Saber" :*: 1537 :*: Nothing :*: 0

overrideAutoIncrement = do
  setup
  insert_ comments [123 :*: Nothing :*: "hello"]
  num <- query $ aggregate $ do
    id :*: _ <- select comments
    restrict (id .== 123)
    return (count id)
  assEq "failed to override auto-incrementing column" [1] num

insertAllDefaults = do
  setup
  pk <- insertWithPK comments [def :*: def :*: def]
  res <- query $ do
    comment@(id :*: _) <- select comments
    restrict (id .== int pk)
    return comment
  assEq "wrong default values inserted" [pk :*: Nothing :*: ""] res

insertSomeDefaults = do
  setup
  insert_ people ["Celes" :*: def :*: Just "chocobo" :*: def]
  res <- query $ do
    person@(id :*: n :*: pet :*: c) <- select people
    restrict (pet .== just "chocobo")
    return person
  assEq "wrong values inserted" ["Celes" :*: 0 :*: Just "chocobo" :*: 0] res

weirdNames = do
  tryDropTable tableWithWeirdNames
  createTable tableWithWeirdNames
  i1 <- insert tableWithWeirdNames [42 :*: Nothing]
  assEq "first insert failed" 1 i1
  i2 <- insert tableWithWeirdNames [123 :*: Just 321]
  assEq "second insert failed" 1 i2
  up <- update tableWithWeirdNames (\c -> c ! weird1 .== 42)
                                   (\c -> c `with` [weird2 := just 11])
  assEq "update failed" 1 up
  res <- query $ do
    t <- select tableWithWeirdNames
    restrict (t ! weird1 .== 42)
    return (t ! weird2)
  assEq "select failed" [Just 11] res
  dropTable tableWithWeirdNames
  where
    tableWithWeirdNames :: Table (Int :*: Maybe Int)
    (tableWithWeirdNames, weird1 :*: weird2) =
          tableWithSelectors "DROP TABLE comments"
      $   required "one \" quote \1\2\3\DEL"
      :*: optional "two \"quotes\""

nulIdentifiersFail = do
  e1 <- try (createTable nulTable) :: SeldaM (Either ValidationError ())
  e2 <- try (createTable nulColTable) :: SeldaM (Either ValidationError ())
  case (e1, e2) of
    (Left _, Left _) -> return ()
    _                -> liftIO $ assertFailure "ValidationError not thrown"
  where
    nulTable :: Table Int
    nulTable = table "table_\0" $ required "blah"

    nulColTable :: Table Int
    nulColTable = table "nul_col_table" $ required "col_\0"

emptyIdentifiersFail = do
  e1 <- try (createTable noNameTable) :: SeldaM (Either ValidationError ())
  e2 <- try (createTable noColNameTable) :: SeldaM (Either ValidationError ())
  case (e1, e2) of
    (Left _, Left _) -> return ()
    _                -> liftIO $ assertFailure "ValidationError not thrown"
  where
    noNameTable :: Table Int
    noNameTable = table "" $ required "blah"

    noColNameTable :: Table Int
    noColNameTable = table "table with empty col name" $ required ""

duplicateColsFail = do
  e <- try (createTable dupes) :: SeldaM (Either ValidationError ())
  case e of
    Left _ -> return ()
    _      -> liftIO $ assertFailure "ValidationError not thrown"
  where
    dupes :: Table (Int :*: Text)
    dupes = table "duplicate" $ required "blah" :*: required "blah"

duplicatePKsFail = do
  e1 <- try (createTable dupes1) :: SeldaM (Either ValidationError ())
  e2 <- try (createTable dupes2) :: SeldaM (Either ValidationError ())
  case (e1, e2) of
    (Left _, Left _) -> return ()
    _                -> liftIO $ assertFailure "ValidationError not thrown"
  where
    dupes1 :: Table (Int :*: Text)
    dupes1 = table "duplicate" $ primary "blah1" :*: primary "blah2"
    dupes2 :: Table (Int :*: Text)
    dupes2 = table "duplicate" $ autoPrimary "blah1" :*: primary "blah2"

dupeInsertThrowsSeldaError = do
  setup
  assertFail $ do
    insert_ comments
      [ 0 :*: Just "Kobayashi" :*: "チョロゴン"
      , 0 :*: Nothing          :*: "some spam"
      ]

dupeInsert2ThrowsSeldaError = do
  setup
  insert_ comments [0 :*: Just "Kobayashi" :*: "チョロゴン"]
  e <- try $ insert_ comments [0 :*: Nothing :*: "Spam, spam, spaaaaaam!"]
  case e :: Either SeldaError () of
    Left _ -> return ()
    _      -> liftIO $ assertFailure "SeldaError not thrown"

dupeUpdateThrowsSeldaError = do
  setup
  insert_ comments
    [ 0   :*: Just "Kobayashi" :*: "チョロゴン"
    , def :*: Just "spammer"   :*: "some spam"
    ]
  e <- try $ do
    update_ comments
      (\c -> c ! cName .== just "spammer")
      (\c -> c `with` [cId := 0])
  case e :: Either SeldaError () of
    Left _ -> return ()
    _      -> liftIO $ assertFailure "SeldaError not thrown"

nulQueries = do
  setup
  insert_ comments
    [ def :*: Just "Kobayashi" :*: "チョロゴン"
    , def :*: Nothing          :*: "more \0 spam"
    , def :*: Nothing          :*: "even more spam"
    ]
  rows <- update comments (isNull . second)
                          (\(id :*: _ :*: c) -> (id :*: just "\0" :*: c))
  [upd] <- query $ aggregate $ do
    _ :*: name :*: _ <- select comments
    restrict (not_ $ isNull name)
    restrict (name .== just "\0")
    return (count name)
  assEq "update returns wrong number of updated rows" 3 rows
  assEq "rows were not updated" 3 upd

invalidateCacheAfterTransaction run = run $ do
  setLocalCache 1000
  createTable comments
  createTable addresses
  lock <- liftIO $ newEmptyMVar

  -- This thread repopulates the cache for the query before the transaction
  -- in which it was invalidated finishes
  liftIO $ forkIO $ run $ do
    liftIO $ takeMVar lock
    query $ do
      c <- select comments
      restrict (c ! cName .== just "Link")
      return (c ! cComment)
    liftIO $ putMVar lock ()

  insert_ comments [def :*: Just "Link" :*: "spam"]
  transaction $ do
    update_ comments
      (\c -> c ! cName .== just "Link")
      (\c -> c `with` [cComment := "insightful comment"])
    liftIO $ putMVar lock ()
    liftIO $ takeMVar lock
    insert_ addresses [def :*: def]

  -- At this point, the comment in the database is "insightful comment", but
  -- unless the cache is re-invalidated *after* the transaction finishes,
  -- the cached comment will be "spam".
  [comment] <- query $ do
    c <- select comments
    restrict (c ! cName .== just "Link")
    return (c ! cComment)
  assEq "" "insightful comment" comment
