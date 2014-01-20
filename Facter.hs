{-# LANGUAGE LambdaCase #-}
module Facter where

import Data.Char
import Text.Printf
import qualified Data.HashSet as HS
import qualified Data.HashMap.Strict as HM
import Puppet.Interpreter.Types
import System.Info
import qualified Data.Text as T
import Control.Arrow
import qualified Data.Either.Strict as S
import Control.Lens
import System.Posix.User
import System.Posix.Unistd (getSystemID, SystemID(..))
import Data.List.Split (splitOn)
import Data.List (intercalate)

storageunits :: [(String, Int)]
storageunits = [ ("", 0), ("K", 1), ("M", 2), ("G", 3), ("T", 4) ]

getPrefix :: Int -> String
getPrefix n | null fltr = error $ "Could not get unit prefix for order " ++ show n
            | otherwise = fst $ head fltr
    where fltr = filter (\(_, x) -> x == n) storageunits

getOrder :: String -> Int
getOrder n | null fltr = error $ "Could not get order for unit prefix " ++ show n
           | otherwise = snd $ head fltr
    where
        nu = map toUpper n
        fltr = filter (\(x, _) -> x == nu) storageunits

normalizeUnit :: (Double, Int) -> Double -> (Double, Int)
normalizeUnit (unit, order) base | unit > base = normalizeUnit (unit/base, order + 1) base
                                 | otherwise = (unit, order)

storagedesc :: (String, String) -> String
storagedesc (ssize, unit) = let
    size = read ssize :: Double
    uprefix | unit == "B" = ""
            | otherwise = [head unit]
    uorder = getOrder uprefix
    (osize, oorder) = normalizeUnit (size, uorder) 1024
    in printf "%.2f %sB" osize (getPrefix oorder)

factRAM :: IO [(String, String)]
factRAM = do
    meminfo <- fmap (map words . lines) (readFile "/proc/meminfo")
    let memtotal  = ginfo "MemTotal:"
        memfree   = ginfo "MemFree:"
        swapfree  = ginfo "SwapFree:"
        swaptotal = ginfo "SwapTotal:"
        ginfo st  = sdesc $ head $ filter ((== st) . head) meminfo
        sdesc [_, size, unit] = storagedesc (size, unit)
    return [("memorysize", memtotal), ("memoryfree", memfree), ("swapfree", swapfree), ("swapsize", swaptotal)]

factNET :: IO [(String, String)]
factNET = return [("ipaddress", "192.168.0.1")]

factOS :: IO [(String, String)]
factOS = do
    lsb <- fmap (map (break (== '=')) . lines) (readFile "/etc/lsb-release")
    let getval st | null filterd = "?"
                  | otherwise = rvalue
                  where filterd = filter (\(k,_) -> k == st) lsb
                        value    = (tail . snd . head) filterd
                        rvalue | head value == '"' = read value
                               | otherwise         = value
        lrelease = getval "DISTRIB_RELEASE"
        distid  = getval "DISTRIB_ID"
        maj     | lrelease == "?" = "?"
                | otherwise = fst $ break (== '.') lrelease
        osfam   | distid == "Ubuntu" = "Debian"
                | otherwise = distid
    return  [ ("lsbdistid"              , distid)
            , ("operatingsystem"        , distid)
            , ("lsbdistrelease"         , lrelease)
            , ("operatingsystemrelease" , lrelease)
            , ("lsbmajdistrelease"      , maj)
            , ("osfamily"               , osfam)
            , ("lsbdistcodename"        , getval "DISTRIB_CODENAME")
            , ("lsbdistdescription"     , getval "DISTRIB_DESCRIPTION")
            ]

factMountPoints :: IO [(String, String)]
factMountPoints = do
    mountinfo <- fmap (map words . lines) (readFile "/proc/mounts")
    let ignorefs = HS.fromList
                    ["NFS", "nfs", "nfs4", "nfsd", "afs", "binfmt_misc", "proc", "smbfs",
                    "autofs", "iso9660", "ncpfs", "coda", "devpts", "ftpfs", "devfs",
                    "mfs", "shfs", "sysfs", "cifs", "lustre_lite", "tmpfs", "usbfs", "udf",
                    "fusectl", "fuse.snapshotfs", "rpc_pipefs", "configfs", "devtmpfs",
                    "debugfs", "securityfs", "ecryptfs", "fuse.gvfs-fuse-daemon", "rootfs"
                    ]
        goodlines = filter (\x -> not $ HS.member (x !! 2) ignorefs) mountinfo
        goodfs = map (!! 1) goodlines
    return [("mountpoints", unwords goodfs)]

fversion :: IO [(String, String)]
fversion = return [("facterversion", "0.1"),("environment","test")]

factUser :: IO [(String, String)]
factUser = do
    username <- getLoginName
    return [("id",username)]

factUName :: IO [(String, String)]
factUName = do
    SystemID sn nn rl _ mc <- getSystemID
    let vparts = splitOn "." (takeWhile (/='-') rl)
    return [ ("kernel"           , sn)                              -- Linux
           , ("kernelmajversion" , intercalate "." (take 2 vparts)) -- 3.5
           , ("kernelrelease"    , rl)                              -- 3.5.0-45-generic
           , ("kernelversion"    , intercalate "." (take 3 vparts)) -- 3.5.0
           , ("hardwareisa"      , mc)                              -- x86_64
           , ("hardwaremodel"    , mc)                              -- x86_64
           , ("hostname"         , nn)
           ]

puppetDBFacts :: T.Text -> PuppetDBAPI -> IO (Container T.Text)
puppetDBFacts ndename pdbapi =
    getFacts pdbapi (QEqual FCertname ndename) >>= \case
        S.Right facts@(_:_) -> return (HM.fromList (map (\f -> (f ^. factname, f ^. factval)) facts))
        _ -> do
            rawFacts <- fmap concat (sequence [factNET, factRAM, factOS, fversion, factMountPoints, factOS, factUser, factUName])
            let ofacts = genFacts $ map (T.pack *** T.pack) rawFacts
                (hostname, ddomainname) = T.break (== '.') ndename
                domainname = if T.null ddomainname
                                 then ""
                                 else T.tail ddomainname
                nfacts = genFacts [ ("fqdn", ndename)
                                  , ("hostname", hostname)
                                  , ("domain", domainname)
                                  , ("rootrsa", "xxx")
                                  , ("operatingsystem", "Ubuntu")
                                  , ("puppetversion", "language-puppet")
                                  , ("virtual", "xenu")
                                  , ("clientcert", ndename)
                                  , ("is_virtual", "true")
                                  ]
                allfacts = nfacts `HM.union` ofacts
                genFacts = HM.fromList
            return allfacts

