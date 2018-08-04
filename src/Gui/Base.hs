{-# LANGUAGE BangPatterns #-}
module Gui.Base where

import Paths (getDataDir)

import Control.Monad (forM_, void, when)
import Control.Arrow ((***))
import Control.DeepSeq
import Data.Char (chr, toLower)
import Data.IORef
import Data.List (isPrefixOf, foldl1')
import Data.Maybe (isJust, isNothing, fromJust)
import Graphics.UI.Gtk
  hiding (Color, Action, Font, ArrowType, Arrow, Fill, ArrowClass, Image,get,set)
import qualified Graphics.UI.Gtk as Gtk (get,set)
import qualified Graphics.UI.Gtk as Gtk (Color(..))
import Graphics.Rendering.Cairo as Cairo
import Graphics.UI.Gtk.General.CssProvider
import Graphics.UI.Gtk.General.StyleContext
import Graphics.UI.Gtk.General.Enums (PathPriorityType(PathPrioApplication))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeExtension, (<.>), (</>), takeDirectory)
import qualified Data.Text as Text

-- | Main window icon file.
iconFile, cssFile :: FilePath
iconFile = "icon" <.> "png"
cssFile  = "style" <.> "css"

stylePath :: IO FilePath
stylePath = do
    dataDir <- getDataDir
    return $ dataDir </> "style"

-- | 'Graphics.UI.Gtk.Gdk.Pixbuf.Pixbuf' for main window icon file.
iconPixbuf :: IO Pixbuf
iconPixbuf = do
    sty <- stylePath
    pixbufNewFromFile $ sty </> iconFile

-- O'Haskell types
type Action = IO ()
type Request = IO
type Template = IO
type Cmd = IO

-- O'Haskell constructs
while :: Request Bool -> Action -> Action
while mb act = do
    b <- mb 
    when b $ do
        act
        while mb act 

done :: Action
done = return ()

-- CSS
loadCSS :: IO ()
loadCSS = do
    provider <- cssProviderNew
    Just display <- displayGetDefault
    screen <- displayGetDefaultScreen display
    styleContextAddProviderForScreen screen provider
        (fromEnum PathPrioApplication)
    path <- stylePath
    cssProviderLoadFromPath provider (path </> cssFile)

-- glade
loadGlade :: String -> IO Builder
loadGlade glade = do
    builder <- builderNew
    path <- stylePath
    let file = path </> glade <.> "glade"
    builderAddFromFile builder file
    return builder

-- | Sets background of a GTK+ widget.
setBackground :: WidgetClass widget => widget -> Background -> Action
setBackground w (Background name) = do
    sc <- widgetGetStyleContext w
    classes <- styleContextListClasses sc :: IO [String]
    forM_ classes
        $ \cl -> when ("bg_" `isPrefixOf` cl) $ styleContextRemoveClass sc cl
    styleContextAddClass sc name

-- | Adds a CSS class to a GTK+ widget.
addContextClass :: WidgetClass widget => widget -> String -> Action
addContextClass widget cl = do
    context <- widgetGetStyleContext widget
    styleContextAddClass context cl
-- Colors

data Color = RGB Int Int Int deriving Eq

black, white, red, green, blue, yellow, grey, magenta, cyan, orange, brown
    , darkGreen :: Color
black     = RGB 0 0 0
white     = RGB 255 255 255
red       = RGB 255 0 0
green     = RGB 0 255 0
blue      = RGB 0 0 255
yellow    = RGB 255 255 0
grey      = RGB 200 200 200
magenta   = RGB 255 0 255
cyan      = RGB 0 255 255
orange    = RGB 255 180 0
brown     = RGB 0 160 255
darkGreen = RGB 0 150 0

toGtkColor :: Color -> Gtk.Color
toGtkColor (RGB r g b)
    = Gtk.Color (fromIntegral r) (fromIntegral g) (fromIntegral b)

-- Auxiliary types for options

data None                  = None
data AnchorType       = NW | N | NE | W | C | E | SW | S | SE 
data ReliefType       = Raised | Sunken | Flat | Ridge | Solid | Groove
data VertSide         = Top | Bottom 
data WrapType         = NoWrap | CharWrap | WordWrap
data SelectType       = Single | Multiple
data Align            = LeftAlign | CenterAlign | RightAlign
data Round            = Round
data ArcStyleType     = Pie | Chord | Perimeter deriving Eq
data CapStyleType     = Butt | Proj 
data JoinStyleType    = Bevel | Miter 
data ArrowType        = First | Last | Both deriving (Show, Eq, Enum)
data Rotation         = Counterclockwise | RotateUpsidedown | RotateClockwise
  deriving (Show, Eq, Enum)

-- Options

data Anchor       = Anchor AnchorType
data ArcStyle     = ArcStyle ArcStyleType
data Arrow a      = Arrow a
data Background   = Background String
data CapStyle a   = CapStyle a
data Fill         = Fill Color
data Image        = Image Pixbuf
data JoinStyle a  = JoinStyle a
data Justify      = Justify Align
data Outline      = Outline Color
data Smooth       = Smooth Bool
data Width        = Width Double

-- TextOpt
data TextOpt = TextOpt
    { textFont :: Maybe FontDescription
    , textJustify :: Align
    , textAnchor :: AnchorType
    , textFill :: Color
    }

textOpt :: TextOpt
textOpt = TextOpt
    Nothing
    LeftAlign
    C
    black

-- LineOpt
data LineOpt = LineOpt
    { lineFill :: Color
    , lineWidth :: Double
    , lineArrow :: Maybe ArrowType
    , lineCapStyle :: LineCap
    , lineJoinStyle :: LineJoin
    , lineAntialias :: Bool
    , lineSmooth    :: Bool
    } deriving (Show, Eq)

lineOpt :: LineOpt
lineOpt = LineOpt black 1 Nothing LineCapButt LineJoinMiter True False

-- PolygonOpt
data PolygonOpt = PolygonOpt
    { polygonAntialias :: Bool
    , polygonOutline   :: Color
    , polygonFill      :: Maybe Color
    , polygonWidth     :: Double
    , polygonSmooth    :: Bool
    }
polygonOpt :: PolygonOpt
polygonOpt = PolygonOpt True black Nothing 1 False

-- ArcOpt
data ArcOpt = ArcOpt
    { arcFill    :: Maybe Color
    , arcWidth   :: Double
    , arcOutline :: Color
    , arcStyle   :: ArcStyleType
    }

arcOpt :: ArcOpt
arcOpt = ArcOpt Nothing 1 black Pie

-- OvalOpt
data OvalOpt = OvalOpt
    { ovalFill    :: Maybe Color
    , ovalWidht   :: Double
    , ovalOutline :: Color
    }

ovalOpt :: OvalOpt
ovalOpt = OvalOpt Nothing 1 black

-- ImageOpt
data ImageOpt = ImageOpt
  { imageRotate :: Double
  , imageScale  :: Double
  , imageAnchor :: AnchorType
  }

imageOpt :: ImageOpt
imageOpt = ImageOpt 0.0 1.0 C

imageGetSize :: Image -> IO Pos
imageGetSize (Image buf)
  = (,) <$> (pixbufGetWidth buf) <*> (pixbufGetHeight buf)

-- data MenuOpt        > WindowOpt, Enabled
-- data MButtonOpt     > StdOpt, FontOpt, PadOpt, Img, Btmp, Underline, 

-- Unparser

instance Show ArcStyleType where show Pie       = "pieslice"
                                 show Chord     = "chord"
                                 show Perimeter = "arc"


instance Show Color where 
   showsPrec _ (RGB r g b) rest = "#" ++ concatMap (hex 2 "") [r,g,b] ++ rest
                    where hex 0 rs _ = rs
                          hex t rs 0 = hex (t-1) ('0':rs) 0
                          hex t rs i = hex (t-1)(chr (48+m+7*div m 10):rs) d
                                       where m = mod i 16; d = div i 16



type Pos = (Int, Int)

-- TODO What is the String for?
delay :: Int -> Action -> Action
delay millisecs act = void $ timeoutAdd (act >> return False) millisecs

data Runnable = Runnable
    { runnableStart :: Action
    , runnableStop  :: Action
    }

{- |
    Uses Graphics.UI.Gtk.General.General.timoutAdd function from the
    gtk3 package to synchronize with GTK3 main loop. Old version did
    something similar but used the Tcl/Tk API.
-}
periodic :: Int -> Cmd () -> Request Runnable
periodic millisecs act = do
    handlerID <- newIORef Nothing -- Nothing == not running
    
    return Runnable
        { runnableStart = do
            maybeID <- readIORef handlerID
            when (isNothing maybeID) $ do -- if not running
                id <- timeoutAdd (act >> return True) millisecs
                writeIORef handlerID $ Just id
        , runnableStop  = do
            maybeID <- readIORef handlerID
            when (isJust maybeID) $ do -- if running
                timeoutRemove $fromJust maybeID
                writeIORef handlerID Nothing
        }

-- Canvas
data ImageFileType = PNG | PDF | PS | SVG deriving (Read, Show, Enum, Eq)

data Canvas = Canvas
    { canvasOval           :: (Double, Double) -> (Double, Double)
                           -> OvalOpt -> Action
    , canvasArc            :: (Double, Double) -> Double
                           -> (Double, Double) -> ArcOpt -> Action
    , canvasRectangle      :: Pos -> Pos -> OvalOpt -> Action
    , line                 :: [Pos] -> LineOpt -> Action
    , canvasPolygon        :: [Pos] -> PolygonOpt -> Action
    , canvasText           :: Pos -> TextOpt -> String -> Action
    , canvasImage          :: Pos -> ImageOpt -> Image -> Action
    --, cwindow   :: Pos        -> [CWindowOpt] -> Request CWindow
    , clear                :: Action
    , canvasSave           :: FilePath -> Request FilePath
    , canvasSetSize        :: Pos -> Action
    , canvasGetSize        :: Request Pos
    , canvasSetBackground  :: Color -> Action
    , canvasGetBackground  :: Request Color
    , getDrawingArea       :: DrawingArea
    , getSurface           :: Request Surface
    , getTextWidth         :: FontDescription -> String -> Request Double
    , getTextHeight        :: FontDescription -> Request Pos
    , canvasSetCursor      :: CursorType -> Action
    }

data MenuOpt = MenuOpt { font :: Maybe String, background :: Maybe Background }
menuOpt :: MenuOpt
menuOpt = MenuOpt { font = Nothing, background = Nothing }

-- Tk.Menu.cascade
cascade :: Menu -> String -> MenuOpt -> Request Menu
cascade menu label MenuOpt{ font = menuFont, background = bg } = do
  item <- menuItemNewWithLabel label
  menuShellAppend menu item
  doMaybe (addContextClass item) menuFont
  doMaybe (setBackground item) bg
  subMenu <- menuNew
  item `Gtk.set` [ menuItemSubmenu := subMenu, widgetVisible := True ]
  return subMenu
  where
    doMaybe act (Just v) = act v
    doMaybe _ Nothing    = return ()

-- SMOOTHNESS

smooth' :: [(Double,Double)] -> [(Double,Double)]
smooth' ps = interpolate' $!! clean $!! spline' ps
    where clean (p:ps) = p : dropWhile (==p) ps
          clean [] = []

-- spline is used by 'Ecom.hulls', 'Ecom.splinePict' and 'smooth'.
-- It has been moved from "Epaint".
spline :: [(Double,Double)] -> [(Double,Double)]
spline ps@(p:_:_:_) = if p == last ps then spline0 True $ init ps
                                      else spline0 False ps
spline ps = ps

-- Stricter version of 'spline'.
spline' :: [(Double,Double)] -> [(Double,Double)]
spline' ps@(p:_:_:_) = if p == last ps then spline0' True $!! init ps
                                      else spline0' False ps
spline' ps = ps

-- spline0 b ps uses ps as control points for constructing a closed (b = True) 
-- resp. open (b = False) B-spline with degree 3; see Paul Burke, Spline Curves 
-- (http://astronomy.swin.edu.au/~pbourke/curves/spline)
-- or Heinrich Müller, B-Spline-Technik, Vorlesung Geometrisches Modellieren 
-- (http://ls7-www.cs.tu-dortmund.de).

spline0 :: Bool -> [(Double,Double)] -> [(Double,Double)]
spline0 b ps = first:map f [1..resolution] ++ map g [1..9] ++
                 [if b then first else ps!!(n-1)]
        where add2 (x,y) (a,b) = (a+x,b+y)
              apply2 f (x,y) = (f x,f y)
              first = f 0; n = length ps; resolution = n*6
              f i = point $ upb*fromIntegral i/fromIntegral resolution 
              g i = point $ upb+fromIntegral i/10
              upb = fromIntegral n-if b then 1 else 3
              point v = foldl1 add2 $ map h [0..n-1]
                        where h i = apply2 (*z) $ ps!!i
                                where z | b && v < u i = blend2 u i $ v-u 0+u n 
                                        | b                 = blend2 u i v
                                        | otherwise         = blend2 t i v 
              t i = if i < 3 then 0 else fromIntegral (min i n)-2
              u i = if i <= n then fromIntegral i else u (i-1)+u (i-n)-u (i-n-1)
              h d s = if d == 0 then 0 else s
              blend2 t i v = h denom1 sum1+h denom2 sum2
                             where ti = t i; ti3 = t $ i+3
                                   denom1 = t (i+2)-ti;  num1 = v-ti
                                   denom2 = ti3-t (i+1); num2 = ti3-v
                                   sum1 = num1/denom1*blend1 t i v
                                   sum2 = num2/denom2*blend1 t (i+1) v
              blend1 t i v = h denom1 sum1+h denom2 sum2
                             where ti = t i; ti1 = t $ i+1; ti2 = t $ i+2
                                   denom1 = ti1-ti;  num1 = v-ti 
                                   denom2 = ti2-ti1; num2 = ti2-v
                                   sum1 = if b i then num1/denom1 else 0
                                   sum2 = if b $ i+1 then num2/denom2 else 0
                                   b i = t i <= v && v < t (i+1)

spline0' :: Bool -> [(Double,Double)] -> [(Double,Double)]
spline0' b ps = first:map f [1..resolution] ++ map g [1..9] ++
                 [if b then first else ps!!(n-1)]
        where add2 (x,y) (a,b) = let !r1 = a+x
                                     !r2 = b+y
                                 in (r1, r2)
              apply2 f (x,y) = let !r1 = f x
                                   !r2 = f y
                               in (r1, r2)
              first = f 0; !n = length ps; !resolution = n*6
              f i = point $!! upb*fromIntegral i/fromIntegral resolution 
              g i = point $!! upb+fromIntegral i/10
              !n' = fromIntegral n
              upb = n'-if b then 1 else 3
              point v = foldl1' add2 $!! map h [0..n-1]
                        where h i = apply2 (*z) $ ps!!i
                               where z | b && v < u i = blend2 u i $!! v-u 0+u n
                                       | b                 = blend2 u i v
                                       | otherwise         = blend2 t i v 
              t i | i < 3     = 0
                  | otherwise = fromIntegral (min i n)-2
              u i | i <= n    = fromIntegral i
                  | otherwise = u (i-1)+u (i-n)-u (i-n-1)
              h 0 _ = 0
              h _ s = s
              blend2 t i v = h denom1 sum1+h denom2 sum2
                             where ti = t i; ti3 = t $!! i+3
                                   denom1 = t (i+2)-ti;  num1 = v-ti
                                   denom2 = ti3-t (i+1); num2 = ti3-v
                                   sum1 = num1/denom1*blend1 t i v
                                   sum2 = num2/denom2*blend1 t (i+1) v
              blend1 t i v = h denom1 sum1+h denom2 sum2
                             where ti = t i; ti1 = t $ i+1; ti2 = t $ i+2
                                   denom1 = ti1-ti;  num1 = v-ti 
                                   denom2 = ti2-ti1; num2 = ti2-v
                                   sum1 = if b i then num1/denom1 else 0
                                   sum2 = if b $ i+1 then num2/denom2 else 0
                                   b i = t i <= v && v < t (i+1)

{- |
Calculate multiple helper positions for beziere curves out of a
straight line path.
-}
interpolate' :: [(Double,Double)] -> [(Double,Double)]
interpolate' pss@(p1:p2:_:_) = p1:q1:interpolate0 pss
    where scale = 0.35
          !closed = p1 == last pss
          p0 = last $!! init pss
          mag (x,y) = let !r1 = (x ** 2)
                          !r2 = (y ** 2)
                      in sqrt $! (r1 + r2)
          skalar s (x,y) = let !r1 = s*x
                               !r2 = s*y
                           in (r1, r2)
          norm v = skalar (1 / mag v) v
          calc op (x1,y1) (x2,y2) = let !r1 = x1 `op` x2
                                        !r2 = y1 `op` y2
                                    in (r1, r2)
          sub = calc (-)
          add = calc (+)
          -- mul = calc (*)
          tangent = if closed then norm $!! sub p2 p0
                    else sub p2 p1
          q1 = if closed
               then add p1 $ skalar (scale * mag (sub p2 p1)) tangent
               else add p1 $ skalar scale tangent
          interpolate0 (p0:p1:p2:ps) = q0:p1:q1:interpolate0 (p1:p2:ps)
            where tangent = norm $!! sub p2 p0
                  q0 = sub p1 $!! skalar (scale * mag (sub p1 p0)) tangent
                  q1 = add p1 $!! skalar (scale * mag (sub p2 p1)) tangent
          interpolate0 [p0, p1] = [q0, p1]
            where tangent = if closed then norm $!! sub p2 p0
                            else sub p1 p0
                  q0 = if closed
                       then sub p1 $!! skalar (scale * mag (sub p1 p0)) tangent
                       else sub p1 (skalar scale tangent)
          interpolate0 _ = error "Gui.interpolate: interpolate' should never be\
                                \ called with list of length < 2."
interpolate' pss = pss


--- Packing
{-
The Following packing code tries to emulate the original O'Haskell
behavior. It is not really perfect at doing so. Future versions
should use GTK+ own layout system anyway.
-}
data PackableType = Row | Col
data Packable
    = SinglePack
        { packablePacking :: Packing
        , packableSpacing :: Int
        , packableWidget :: Widget
        }
    | MultiPack
        { packablePacking :: Packing
        , packableSpacing :: Int
        , packableType :: PackableType
        , defaultSpacing :: Int
        , packableList :: [Packable]
        }

mkPack :: WidgetClass a => a -> Packable
mkPack = SinglePack PackNatural 0 . toWidget

pack :: Window -> Packable -> Action
pack win SinglePack{ packableWidget = w } = do
        win `Gtk.set` [ containerChild := w ]
        widgetShowAll win
pack win MultiPack{ packableType = pt, defaultSpacing = ds, packableList = ps }
    = do
        box <- newBox pt ds
        mapM_ (append box) ps
        win `Gtk.set` [ containerChild := box ]
        widgetShowAll win
    where newBox pt  = case pt of
                        Row -> fmap toBox . hBoxNew False
                        Col -> fmap toBox . vBoxNew False
          append box (SinglePack p s w) = boxPackStart box w p s
          append box (MultiPack p s t d ps)        = do
                boxChild <- newBox t d
                mapM_ (append boxChild) ps
                boxPackStart box boxChild p s

(<<<), (^^^) :: Packable -> Packable -> Packable
p1 <<< p2 = row [p1,p2]
p1 ^^^ p2 = col [p1,p2]

row,col :: [Packable] -> Packable
row []       = error "row []" 
row as = MultiPack PackNatural 0 Row 0 as
col []       = error "col []" 
col as = MultiPack PackNatural 0 Col 0 as

fillX, fillY, fill, rigid :: Packable -> Packable
fillX p@MultiPack { packableType = Row, packableList = ps }
    = p{ packableList = map (fillX . Gui.Base.fill) ps }
fillX p@MultiPack { packableList = ps } = p{ packableList = map fillX ps }
fillX p = p
fillY p@MultiPack { packableType = Col, packableList = ps }
    = p{ packableList = map (fillY . Gui.Base.fill) ps }
fillY p@MultiPack { packableList = ps } = p{ packableList = map fillY ps }
fillY p = p
fill p = p{ packablePacking = PackGrow }
rigid p = p{ packablePacking = PackNatural }


spacing :: Int -> Packable -> Packable
spacing s p = p{ packableSpacing = s }
