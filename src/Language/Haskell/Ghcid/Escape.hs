{-# LANGUAGE PatternGuards #-}

-- Copyright Neil Mitchell 2014-2018.
-- All rights reserved.
-- 
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
-- 
--     * Redistributions of source code must retain the above copyright
--       notice, this list of conditions and the following disclaimer.
-- 
--     * Redistributions in binary form must reproduce the above
--       copyright notice, this list of conditions and the following
--       disclaimer in the documentation and/or other materials provided
--       with the distribution.
-- 
--     * Neither the name of Neil Mitchell nor the names of other
--       contributors may be used to endorse or promote products derived
--       from this software without specific prior written permission.
-- 
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
-- "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
-- LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
-- A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
-- OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
-- SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
-- LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
-- DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
-- THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
-- OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-- | Module for dealing with escape codes
module Language.Haskell.Ghcid.Escape(
    Esc(..), unescape,
    stripInfixE, stripPrefixE, isPrefixOfE, spanE, trimStartE, unwordsE, unescapeE,
    chunksOfWordE
    ) where

import Data.Char
import Data.Either.Extra
import Data.List.Extra
import Data.Maybe
import Data.Tuple.Extra
import Control.Applicative
import Prelude


-- A string with escape characters in it
newtype Esc = Esc {fromEsc :: String}
    deriving (Eq,Show)

app (Esc x) (Esc y) = Esc $ x ++ y

unesc :: Esc -> Maybe (Either Esc Char, Esc)
unesc (Esc ('\ESC':xs)) | (pre,'m':post) <- break (== 'm') xs = Just (Left $ Esc $ '\ESC':pre++"m", Esc post)
unesc (Esc (x:xs)) = Just (Right x, Esc xs)
unesc (Esc []) = Nothing

explode :: Esc -> [Either Esc Char]
explode = unfoldr unesc

implode :: [Either Esc Char] -> Esc
implode = Esc . concatMap (either fromEsc return)

unescape :: String -> String
unescape = unescapeE . Esc

-- | Remove all escape characters in a string
unescapeE :: Esc -> String
unescapeE = rights . explode

stripPrefixE :: String -> Esc -> Maybe Esc
stripPrefixE [] e = Just e
stripPrefixE (x:xs) e = case unesc e of
    Just (Left code, rest) -> app code <$> stripPrefixE (x:xs) rest
    Just (Right y, rest) | y == x -> stripPrefixE xs rest
    _ -> Nothing

stripInfixE :: String -> Esc -> Maybe (Esc, Esc)
stripInfixE needle haystack | Just rest <- stripPrefixE needle haystack = Just (Esc [], rest)
stripInfixE needle e = case unesc e of
    Nothing -> Nothing
    Just (x,xs) -> first (app $ fromEither $ fmap (Esc . return) x) <$> stripInfixE needle xs


spanE, breakE :: (Char -> Bool) -> Esc -> (Esc, Esc)
breakE f = spanE (not . f)
spanE f e = case unesc e of
    Nothing -> (Esc "", Esc "")
    Just (Left e, rest) -> first (app e) $ spanE f rest
    Just (Right c, rest) | f c -> first (app $ Esc [c]) $ spanE f rest
                         | otherwise -> (Esc "", e)

isPrefixOfE :: String -> Esc -> Bool
isPrefixOfE x y = isJust $ stripPrefixE x y

trimStartE :: Esc -> Esc
trimStartE e = case unesc e of
    Nothing -> Esc ""
    Just (Left code, rest) -> app code $ trimStartE rest
    Just (Right c, rest) | isSpace c -> trimStartE rest
                         | otherwise -> e

unwordsE :: [Esc] -> Esc
unwordsE = Esc . unwords . map fromEsc


repeatedlyE :: (Esc -> (b, Esc)) -> Esc -> [b]
repeatedlyE f (Esc []) = []
repeatedlyE f as = b : repeatedlyE f as'
    where (b, as') = f as

splitAtE :: Int -> Esc -> (Esc, Esc)
splitAtE i e = case unesc e of
    _ | i <= 0 -> (Esc "", e)
    Nothing -> (e, e)
    Just (Left code, rest) -> first (app code) $ splitAtE i rest
    Just (Right c, rest) -> first (app $ Esc [c]) $ splitAtE (i-1) rest

reverseE :: Esc -> Esc
reverseE = implode . reverse . explode

breakEndE :: (Char -> Bool) -> Esc -> (Esc, Esc)
breakEndE f = swap . both reverseE . breakE f . reverseE


lengthE :: Esc -> Int
lengthE = length . unescapeE

-- | Like chunksOf, but deal with words up to some gap.
--   Flows onto a subsequent line if less than N characters end up being empty.
chunksOfWordE :: Int -> Int -> Esc -> [Esc]
chunksOfWordE mx gap = repeatedlyE $ \x ->
    let (a,b) = splitAtE mx x in
    if b == Esc "" then (a, Esc "") else
        let (a1,a2) = breakEndE isSpace a in
        if lengthE a2 <= gap then (a1, app a2 b) else (a, trimStartE b)
