% Copyright (C) 2009 John Millikin <jmillikin@gmail.com>
% 
% This program is free software: you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation, either version 3 of the License, or
% any later version.
% 
% This program is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
% 
% You should have received a copy of the GNU General Public License
% along with this program.  If not, see <http://www.gnu.org/licenses/>.

\ignore{
\begin{code}
module DBus.Introspection
	( Object (..)
	, Interface (..)
	, Method (..)
	, Signal (..)
	, Parameter (..)
	, Property (..)
	, PropertyAccess (..)
	, toXML
	, fromXML
	) where

import Control.Arrow ((>>>), (&&&), (<+>))
import Control.Monad (mapM)
import Data.Maybe (listToMaybe, maybeToList)
import qualified Text.XML.HXT.Arrow as A
import Text.XML.HXT.Arrow.ParserInterface (parseXmlDoc)
import qualified Text.XML.HXT.DOM.XmlNode as XN
import qualified DBus.Types as T
\end{code}
}

\clearpage
\section{Introspection}

DBus objects may be ``introspected'' to determine which methods, signals,
etc they support. Intospection data is sent over the bus in XML, in a mostly
sane but non-standardised format.

\begin{code}
data Object = Object T.ObjectPath [Interface] [Object]
	deriving (Show)

data Interface = Interface T.InterfaceName [Method] [Signal] [Property]
	deriving (Show)

data Method = Method T.MemberName [Parameter] [Parameter]
	deriving (Show)

data Signal = Signal T.MemberName [Parameter]
	deriving (Show)

data Parameter = Parameter String T.Signature
	deriving (Show)

data Property = Property String T.Signature [PropertyAccess]
	deriving (Show)

data PropertyAccess = Read | Write
	deriving (Show, Eq)
\end{code}

\subsection{Parsing XML}

An XML introspection document looks like this:

\begin{xml}
<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
         "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node name="/org/example/example">
	<interface name="org.example.ExampleInterface">
		<method name="Echo">
			<arg name="text" type="s" direction="in"/>
			<arg type="s" direction="out"/>
		</method>
		<signal name="Echoed">
			<arg type="s"/>
		</signal>
		<property name="EchoCount" type="u" access="read"/>
	</interface>
	<node name="child_a"/>
	<node name="child/b"/>
</node>
\end{xml}

The root {\tt node} is special, in that it's the only {\tt node} which is
not required to have a {\tt name} attribute. If the root has no {\tt name},
its path will default to the path of the introspected object.

If parsing fails, {\tt fromXML} will return {\tt Nothing}. Aside from the
elements directly accessed by the parser, no effort is made to check the
document's validity because there is no DTD as of yet.

\begin{code}
fromXML :: T.ObjectPath -> String -> Maybe Object
fromXML path text = listToMaybe $ (A.runLA arrow) ("", text) where
	arrow = parseXmlDoc
	        >>> A.removeAllWhiteSpace
	        >>> A.single (A.hasName "node")
	        >>> A.arrL (maybeToList . parseRoot path)
\end{code}

Even though the root object's {\tt name} is optional, if present, it must
still be a valid object path.

\begin{code}
parseRoot :: T.ObjectPath -> A.XmlTree -> Maybe Object
parseRoot defaultPath t = do
	path <- case getAttr "name" t of
		"" -> Just defaultPath
		x  -> T.mkObjectPath x
	parseObject' path t
\end{code}

Child {\tt nodes} have ``relative'' paths -- that is, their {\tt name}
attribute is not a valid object path, but should be valid when appended to
the root object's path.

\begin{code}
parseChild :: T.ObjectPath -> A.XmlTree -> Maybe Object
parseChild parentPath t = do
	let parentPath' = case T.strObjectPath parentPath of
		"/" -> "/"
		x   -> x ++ "/"
	pathSegment <- case getAttr "name" t of
		"" -> Nothing
		x  -> Just x
	path <- T.mkObjectPath (parentPath' ++ pathSegment)
	parseObject' path t
\end{code}

Other than the name, both root and non-root {\tt nodes} have identical
contents.  They may contain interface definitions, and child {\tt node}s.

\begin{code}
parseObject' :: T.ObjectPath -> A.XmlTree -> Maybe Object
parseObject' path t = do
	interfaces <- children parseInterface (A.hasName "interface") t
	children' <- children (parseChild path) (A.hasName "node") t
	return $ Object path interfaces children'
\end{code}

Interfaces may contain methods, signals, and properties.

\begin{code}
parseInterface :: A.XmlTree -> Maybe Interface
parseInterface t = do
	name <- T.mkInterfaceName $ getAttr "name" t
	methods <- children parseMethod (A.hasName "method") t
	signals <- children parseSignal (A.hasName "signal") t
	properties <- children parseProperty (A.hasName "property") t
	return $ Interface name methods signals properties
\end{code}

Methods contain a list of parameters, which default to ``in'' parameters
if no direction is specified.

\begin{code}
parseMethod :: A.XmlTree -> Maybe Method
parseMethod t = do
	name <- T.mkMemberName $ getAttr "name" t
	paramsIn <- children parseParameter (isParam ["in", ""]) t
	paramsOut <- children parseParameter (isParam ["out"]) t
	return $ Method name paramsIn paramsOut
\end{code}

Signals are similar to methods, except they have no ``in'' parameters.

\begin{code}
parseSignal :: A.XmlTree -> Maybe Signal
parseSignal t = do
	name <- T.mkMemberName $ getAttr "name" t
	params <- children parseParameter (isParam ["out", ""]) t
	return $ Signal name params
\end{code}

A parameter has a free-form name, and a single valid type.

\begin{code}
parseParameter :: A.XmlTree -> Maybe Parameter
parseParameter t = do
	let name = getAttr "name" t
	sig <- parseType t
	return $ Parameter name sig
\end{code}

\begin{code}
parseType :: A.XmlTree -> Maybe T.Signature
parseType t = do
	sig <- T.mkSignature $ getAttr "type" t
	case T.signatureTypes sig of
		[t'] -> T.mkSignature (T.typeString t')
		_    -> Nothing
\end{code}

Properties are used by the {\tt org.freedesktop.DBus.Properties} interface.
Each property may be read, written, or both, and has an associated type.

\begin{code}
parseProperty :: A.XmlTree -> Maybe Property
parseProperty t = do
	let name = getAttr "name" t
	sig <- parseType t
	access <- case getAttr "access" t of
		""          -> Just []
		"read"      -> Just [Read]
		"write"     -> Just [Write]
		"readwrite" -> Just [Read, Write]
		_           -> Nothing
	return $ Property name sig access
\end{code}

Some helper functions for dealing with HXT xml arrows.

\begin{code}
getAttr :: String -> A.XmlTree -> String
getAttr name t = case A.runLA (A.getAttrValue name) t of
	(x:_) -> x
	_     -> ""

children :: Monad m => (a -> m b) -> A.LA A.XmlTree a -> A.XmlTree -> m [b]
children f a = mapM f . A.runLA (A.getChildren >>> a)

isParam :: A.ArrowXml a => [String] -> a A.XmlTree A.XmlTree
isParam dirs = A.hasName "arg"
               >>> (A.arr id &&& A.getAttrValue "direction")
               >>> A.arrL (\(t, p) -> if elem p dirs then [t] else [])
\end{code}

\subsection{Generating XML}

\begin{code}
toXML :: Object -> String
toXML obj = concat $ A.runLA (A.xshow (dtd <+> xmlRoot obj)) () where
	dtd = A.mkDTDDoctype
		[ ("name", "node")
		, ("SYSTEM", "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd")
		, ("PUBLIC", "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN")
		] A.none
\end{code}

When writing objects to {\tt node}s, the root object must have an absolute
path, and children must have paths relative to their parent.

\begin{code}
xmlRoot :: A.ArrowXml a => Object -> a n A.XmlTree
xmlRoot (Object path interfaces children') = A.mkElement (A.mkName "node")
	(mkAttr "name" (T.strObjectPath path))
	(A.catA . concat $
		[ map xmlInterface interfaces
		, map (xmlObject path) children'
		])
\end{code}

\begin{code}
xmlObject :: A.ArrowXml a => T.ObjectPath -> Object -> a n A.XmlTree
xmlObject parentPath (Object path interfaces children') =
	A.mkElement (A.mkName "node")
		(mkAttr "name" relpath)
		(A.catA . concat $
			[ map xmlInterface interfaces
			, map (xmlObject path) children'
			])
	where
		path' = T.strObjectPath path
		parent' = T.strObjectPath parentPath
		relpath = drop (length parent') path'
\end{code}

\begin{code}
xmlInterface :: A.ArrowXml a => Interface -> a n A.XmlTree
xmlInterface (Interface name methods signals properties) =
	A.mkElement (A.mkName "interface")
		(mkAttr "name" (T.strInterfaceName name))
		(A.catA . concat $
			[ map xmlMethod methods
			, map xmlSignal signals
			, map xmlProperty properties
			])
\end{code}

\begin{code}
xmlMethod :: A.ArrowXml a => Method -> a n A.XmlTree
xmlMethod (Method name inParams outParams) = A.mkElement (A.mkName "method")
	(mkAttr "name" (T.strMemberName name))
	(A.catA . concat $
		[ map (xmlParameter "in") inParams
		, map (xmlParameter "out") outParams
		])
\end{code}

\begin{code}
xmlSignal :: A.ArrowXml a => Signal -> a n A.XmlTree
xmlSignal (Signal name params) = A.mkElement (A.mkName "signal")
	(mkAttr "name" (T.strMemberName name))
	(A.catA (map (xmlParameter "out") params))
\end{code}

\begin{code}
xmlParameter :: A.ArrowXml a => String -> Parameter -> a n A.XmlTree
xmlParameter direction (Parameter name sig) = A.mkElement (A.mkName "arg")
	(A.catA [ mkAttr "name" name
	        , mkAttr "type" $ T.strSignature sig
	        , mkAttr "direction" direction
	        ])
	A.none
\end{code}

\begin{code}
xmlProperty :: A.ArrowXml a => Property -> a n A.XmlTree
xmlProperty (Property name sig access) = A.mkElement (A.mkName "property")
	(A.catA [ mkAttr "name" name
	        , mkAttr "type" $ T.strSignature sig
	        , mkAttr "access" $ xmlAccess access
	        ])
	A.none
\end{code}

\begin{code}
xmlAccess :: [PropertyAccess] -> String
xmlAccess access = read ++ write where
	read = if elem Read access then "read" else ""
	write = if elem Write access then "write" else ""
\end{code}

\begin{code}
mkAttr :: A.ArrowXml a => String -> String -> a n A.XmlTree
mkAttr name value = A.mkAttr (A.mkName name) (A.txt value)
\end{code}