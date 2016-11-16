{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}
module Game.Minecraft.Map where

import Game.Minecraft.Map.NBT
import Game.Minecraft.Map.Block
import Game.Minecraft.Map.Region

import System.Directory
import System.IO
import System.Environment

import Data.Word
import Data.Int
import Data.List
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Maybe
import Data.Bits
import System.Directory
import Codec.Picture
import Codec.Picture.Png

import qualified Data.Vector.Generic         as V
import qualified Data.Vector.Generic.Mutable as MV

import Control.Monad
import Control.Monad.Primitive
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.Chan

import Debug.Trace

data Chunk = Chunk XPos ZPos [[(Word8,Word8)]] deriving (Eq,Show)
type XPos = Int
type ZPos = Int
data ChunkTop = ChunkTop
                {
                    getTopX ::  !XPos,
                    getTopZ ::  !ZPos,
                    getTopData ::  ![(Word8,Word8)]
                } deriving (Eq, Show)

make2D :: Int -> [a] -> [[a]]
make2D _ [] = []
make2D y xs = (Data.List.take y xs) : make2D y (Data.List.drop y xs)

allDraw :: [(Word8,Word8)] -> Bool
allDraw = all ifDraw

toTopView :: Chunk -> ChunkTop
toTopView (Chunk x z bs) = ChunkTop x z (myFoldl' ref e $ reverse bs) where
    e = replicate 256 (0x00,0x00)
    myFoldl' f e [] = e
    myFoldl' f e (x:xs)
        | allDraw e = e
        | otherwise =   let e' = e `f` x
                        in seq e' $ myFoldl' f e' xs
    ref highs lows = zipWith refT highs lows
    refT high low
        | ifDraw high = high
        | otherwise = low

buildChunk :: NBT -> Chunk
buildChunk nbt = 
    let
        c       = contentNBT nbt
        secs    = openList $ fromJust $ navigate ["Level","Sections"] c
        ids     = (concat $ map ( byteArrayContent.fromJust.navigate ["Blocks"] ) secs )
        adds    = (concat $ map ( splitData.byteArrayContent.fromJust.navigate ["Data"] ) secs )
        x       = fromIntegral (fromIntegral . intContent . fromJust $ navigate ["Level","xPos"] c :: Int32) :: Int
        z       = fromIntegral (fromIntegral . intContent . fromJust $ navigate ["Level", "zPos"] c :: Int32 ) :: Int
    in
        Chunk x z (make2D 256 $ zipWith (,) ids adds)

-- 8 bits per block, but 4 bits per additional data, so split it
splitData :: [Word8] -> [Word8]
splitData s = concat $ map sp s where
    sp w = [w `shiftR` 4 , w .&. 0x0F]

loadRegions :: String -> IO [ChunkTop]
loadRegions path = do
    rFiles <- filter (isSuffixOf "mca") <$> listDirectory path
    contents <- sequence $ map (BL.readFile .((path ++ "/") ++ )) rFiles
    --let r =  map (toTopView . buildChunk . getNBT . getRawNBT) (concatMap getChunkRaws contents)
    let r =  map (toTopView . buildChunk . getNBT . getRawNBT) (concatMap getChunkRaws contents)
    return r

loadRegionsP :: String -> IO [ChunkTop]
loadRegionsP path = do
    rFiles <- filter (isSuffixOf "mca") <$> listDirectory path
    contents <- sequence $ map (BL.readFile .((path ++ "/") ++ )) rFiles
    let numCon = length contents
    chTsChan <- newChan
    forM_ [0..numCon-1] $ \i -> do forkIO $ fromOneFile (contents !! i) chTsChan
    r <- reduce chTsChan numCon []
    return r
        where
            fromOneFile content outChan = do
                let chTs = map (toTopView . buildChunk . getNBT . getRawNBT) (getChunkRaws content)
                writeChan outChan chTs
            reduce inChan n nowResult
                    | n == 0 = return nowResult
                    | otherwise = do 
                        chTs <- readChan inChan
                        reduce inChan (n-1) (chTs `seq` chTs++nowResult)






yypFun :: [ChunkTop] -> Image PixelRGBA8

yypFun chunkTopGroup = Image width height (V.fromList $ unfoldMap (insertMap (getSize chunkTopGroup) chunkTopGroup))
--yypFun chunkTopGroup = (,,) width height (unfoldMap (insertMap (getSize chunkTopGroup) chunkTopGroup))
    where
        getSize :: [ChunkTop] -> (Int, Int, Int, Int)
        getSize chunkTopGroup =(maximum xlist, minimum xlist, maximum zlist, minimum zlist)
            where 
                xlist = map (fromIntegral . getTopX) chunkTopGroup :: [Int]
                zlist = map (fromIntegral . getTopZ) chunkTopGroup :: [Int]
        getHW :: (Int, Int, Int, Int) -> (Int, Int)
        getHW (xmax, xmin, zmax, zmin) = mapTuple2 (16*) (xmax - xmin + 1, zmax - zmin + 1)
        (width, height) = getHW . getSize $ chunkTopGroup
        defaultChunk = replicate 16 $ replicate 16  $ replicate 4 (0::Word8)
        insertMap :: (Int, Int, Int, Int) -> [ChunkTop]->[[[[[Word8]]]]]
        insertMap (xmax, xmin, zmax, zmin) chunkTopGroup = [[insertOneChunk (xnow, znow) | xnow <- [xmin..xmax]] | znow <- [zmin..zmax]]
            where
                insertOneChunk :: (Int, Int) -> [[[Word8]]]
                insertOneChunk (x, z)
                    | not $ null (findChunk x z) = make2D 16 $ map getBlockColor $ getTopData $ head $ findChunk x z
                    | otherwise =defaultChunk
                    where
                        findChunk x z = [chunk |chunk <- chunkTopGroup, getTopX chunk == x, getTopZ chunk == z]
        unfoldMap :: [[[[[Word8]]]]] -> [Word8]
        unfoldMap chunkGroup =concat $ map unfoldRow chunkGroup
            where
                unfoldRow :: [[[[Word8]]]] -> [Word8]
                unfoldRow chunkRow = concat $ unfold chunkRow 16 []
                    where
                        unfold :: [[[[Word8]]]] -> Int -> [[Word8]] -> [[Word8]]
                        unfold chunkRow 0 result =result
                        unfold chunkRow num result =unfold [tail chunk | chunk <- chunkRow] (num - 1) (result `seq` result ++ concat [head chunk| chunk <- chunkRow])    

yypFast :: [ChunkTop] -> Image PixelRGBA8
yypFast chunkTopGroup = Image width height (V.fromList $ insertMap (getSize chunkTopGroup) chunkTopGroup)
    where
        getSize :: [ChunkTop] -> (Int, Int, Int, Int)
        getSize chunkTopGroup =(maximum xlist, minimum xlist, maximum zlist, minimum zlist)
            where 
                xlist = map (fromIntegral . getTopX) chunkTopGroup :: [Int]
                zlist = map (fromIntegral . getTopZ) chunkTopGroup :: [Int]
        getHW :: (Int, Int, Int, Int) -> (Int, Int)
        getHW (xmax, xmin, zmax, zmin) = mapTuple2 (16*) (xmax - xmin + 1, zmax - zmin + 1)
        (width, height) = getHW . getSize $ chunkTopGroup
        defaultChunk = replicate 16 $ replicate 16  $ replicate 4 (0::Word8)
        insertMap :: (Int, Int, Int, Int) -> [ChunkTop]-> [Word8]
        insertMap (xmax, xmin, zmax, zmin) chunkTopGroup = insertRow zmin []
            where
                insertOneChunk :: (Int, Int) -> [[[Word8]]]
                insertOneChunk (x, z)
                    | not $ null (findChunk x z) = make2D 16 $ map getBlockColor $ getTopData $ head $ findChunk x z
                    | otherwise =defaultChunk
                    where
                        findChunk x z = [chunk |chunk <- chunkTopGroup, getTopX chunk == x, getTopZ chunk == z]
                
                insertRow :: Int -> [Word8] -> [Word8]
                insertRow znow chunkList
                    | znow >= zmax =chunkList
                    | otherwise =insertRow (znow `seq` znow + 1) (chunkList `seq` chunkList ++ unfoldRow [insertOneChunk (xnow, znow) | xnow <- [xmin..xmax] ] )

                unfoldRow :: [[[[Word8]]]] -> [Word8]
                unfoldRow chunkRow = concat $ unfold chunkRow 16 []
                    where
                        unfold :: [[[[Word8]]]] -> Int -> [[Word8]] -> [[Word8]]
                        unfold chunkRow 0 result =result
                        unfold chunkRow num result =unfold [tail chunk | chunk <- chunkRow] (num `seq` num - 1) (result `seq` result ++ concat [head chunk| chunk <- chunkRow])     

getRange :: [ChunkTop] -> (Int,Int,Int,Int)
getRange chs = foldl' ref e chs where
    e = (0,0,0,0)
    ref (oMinX,oMinZ,oMaxX,oMaxZ) (ChunkTop x z _) = (min oMinX x, min oMinZ z,max oMaxX x, max oMaxZ z)

writeList :: (PrimMonad m, MV.MVector v a) => v (PrimState m) a -> Int -> [a] -> m ()
writeList v pos xs = do
    forM_ [0..(length xs - 1)] (\i -> MV.unsafeWrite v (pos+i) (xs !! i)) 

buildImage1 :: [ChunkTop] -> IO (Image PixelRGBA8)
buildImage1 chs = do
                v <- MV.new n
                forM_ chs $ \ch -> fillChunk ch v
                fv <- V.unsafeFreeze v
                return $ Image (width `shiftL` 4) (height `shiftL` 4) fv
            where
                (minX, minZ, maxX, maxZ) = getRange chs
                width = maxX - minX + 1
                height = maxZ - minZ + 1
                wordPerLine = width`shiftL`6
                n = width * height `shiftL` 10
                fillChunk :: (PrimMonad m, MV.MVector v Word8) => ChunkTop -> v (PrimState m) Word8 -> m ()
                fillChunk (ChunkTop x z chData) v = do
                    let xr = x - minX
                    let zr = z - minZ
                    let chColor = make2D 64 $ concatMap getBlockColor chData
                    forM_ [0..15] $ \row -> writeList v ( wordPerLine *( (zr`shiftL`4) + row) + (xr`shiftL`6) ) (chColor !! row)

lqFun2 :: [ChunkTop] -> Image PixelRGBA8
lqFun2 chs = Image (width `shiftL` 4) (height `shiftL` 4) v
    where
        (minX, minZ, maxX, maxZ) = getRange chs
        width = maxX - minX + 1
        height = maxZ - minZ + 1
        n = width * height `shiftL` 10
        wordPerLine = width`shiftL`6
        v0 = V.replicate n (0::Word8)
        --v = foldl' refV v0 chs
        v = v0 V.// ivpsAll
        ivpsAll = concatMap buildIV chs
        buildIV (ChunkTop x z chData) = map (\i -> (,) (wordPerLine * ((zr`shiftL`4)+(i`shiftR`6)) + xr`shiftL`6 + i`mod`64) (chColor !! i)) [0..1023]
            where
                xr = x - minX
                zr = z - minZ
                chColor = concatMap getBlockColor chData

main :: IO ()
main = do 
        print "starting"
        [inputFile,outputFile] <- getArgs
        print "loading resources..."
        --rs <- loadRegions inputFile
        rs <- loadRegionsP inputFile
        print "buiding image..."
        img <- buildImage1 rs
        print "saving..."
        writePng outputFile img 
        print "done"

