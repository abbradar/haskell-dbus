-- Copyright (C) 2009-2012 John Millikin <jmillikin@gmail.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

module DBus.Address where

import qualified Control.Exception
import           Data.Char (digitToInt, ord, chr)
import           Data.List (intercalate)
import qualified Data.Map
import           Data.Map (Map)
import qualified System.Environment
import           Text.Printf (printf)

import           Text.ParserCombinators.Parsec

-- | When a D-Bus server must listen for connections, or a client must connect
-- to a server, the listening socket's configuration is specified with an
-- /address/. An address contains the /method/, which determines the
-- protocol and transport mechanism, and /parameters/, which provide
-- additional method-specific information about the address.
data Address = Address String (Map String String)
	deriving (Eq)

addressMethod :: Address -> String
addressMethod (Address x _ ) = x

addressParameters :: Address -> Map String String
addressParameters (Address _ x) = x

address :: String -> Map String String -> Maybe Address
address method params = if validMethod method && validParams params
	then if null method && Data.Map.null params
		then Nothing
		else Just (Address method params)
	else Nothing

validMethod :: String -> Bool
validMethod = all validChar where
	validChar c = c /= ';' && c /= ':'

validParams :: Map String String -> Bool
validParams = all validItem . Data.Map.toList where
	validItem (k, v) = notNull k && notNull v && validKey k
	validKey = all validChar
	validChar c = c /= ';' && c /= ',' && c /= '='
	notNull = not . null

optionallyEncoded :: [Char]
optionallyEncoded = concat
	[ ['0'..'9']
	, ['a'..'z']
	, ['A'..'Z']
	, ['-', '_', '/', '\\', '*', '.']
	]

formatAddress :: Address -> String
formatAddress (Address method params) = concat [method, ":", csvParams] where
	csvParams = intercalate "," $ do
		(k, v) <- Data.Map.toList params
		let v' = concatMap escape v
		return (concat [k, "=", v'])
	
	escape c = if elem c optionallyEncoded
		then [c]
		else printf "%%%02X" (ord c)

formatAddresses :: [Address] -> String
formatAddresses = intercalate ";" . map formatAddress

instance Show Address where
	showsPrec d x = showParen (d > 10) $
		showString "Address " .
		shows (formatAddress x)

parseAddress :: String -> Maybe Address
parseAddress = maybeParseString $ do
	addr <- parsecAddress
	eof
	return addr

parseAddresses :: String -> Maybe [Address]
parseAddresses = maybeParseString $ do
	addrs <- sepEndBy parsecAddress (char ';')
	eof
	return addrs

parsecAddress :: Parser Address
parsecAddress = p where
	p = do
		method <- many (noneOf ":;")
		_ <- char ':'
		params <- sepEndBy param (char ',')
		return (Address method (Data.Map.fromList params))
	
	param = do
		key <- many1 (noneOf "=;,")
		_ <- char '='
		value <- many1 valueChar
		return (key, value)
	
	valueChar = encoded <|> unencoded
	encoded = do
		_ <- char '%'
		hex <- count 2 hexDigit
		return (chr (hexToInt hex))
	unencoded = oneOf optionallyEncoded

getSystemAddress :: IO (Maybe Address)
getSystemAddress = do
	let system = "unix:path=/var/run/dbus/system_bus_socket"
	env <- getenv "DBUS_SYSTEM_BUS_ADDRESS"
	return (parseAddress (maybe system id env))

getSessionAddress :: IO (Maybe Address)
getSessionAddress = do
	env <- getenv "DBUS_SESSION_BUS_ADDRESS"
	return (env >>= parseAddress)

getStarterAddress :: IO (Maybe Address)
getStarterAddress = do
	env <- getenv "DBUS_STARTER_ADDRESS"
	return (env >>= parseAddress)

getenv :: String -> IO (Maybe String)
getenv name = Control.Exception.catch
	(fmap Just (System.Environment.getEnv name))
	(\(Control.Exception.SomeException _) -> return Nothing)

hexToInt :: String -> Int
hexToInt = foldl ((+) . (16 *)) 0 . map digitToInt

maybeParseString :: Parser a -> String -> Maybe a
maybeParseString p str = case runParser p () "" str of
	Left _ -> Nothing
	Right a -> Just a
