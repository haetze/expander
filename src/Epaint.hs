{-|
Module      : Epaint
Description : TODO
Copyright   : (c) Peter Padawitz, April 2018
                  Jos Kusiek, April 2018
License     : BSD3
Maintainer  : peter.padawitz@udo.edu
Stability   : experimental
Portability : portable

Epaint contains:

* compilers of trees into pictures,
* the painter,
* functions generating, modifying or combining pictures.
-}
module Epaint where

import Gui.Base hiding (smooth)
import System.Expander
import Gui.Canvas
import Eterm

import Control.Monad
  (when, unless, guard, msum, mplus, mzero, zipWithM_, replicateM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Data.Foldable (forM_)
import Data.IORef
import Data.List (find)
import Data.Maybe (isJust, isNothing, fromJust, fromMaybe)
import Data.Array ((!))
import qualified Data.Text as Text
import Graphics.UI.Gtk
  hiding (Color, Point, Dot, Action, Font, Fill, Arrow, get, set)
import qualified Graphics.UI.Gtk as Gtk (get,set)
import qualified Graphics.UI.Gtk as Gtk (Color(..))
import System.FilePath ((</>), (<.>), splitExtension, takeExtension)

import Prelude hiding ((++),concat)

infixr 5 <:>, <++>

font12 :: Maybe String
font12 = Just "font12"

labFont :: IO FontDescription
labFont = fontDescriptionFromString $ sansSerif ++ " italic 12"

sansSerif, monospace, defaultButton :: String
sansSerif = "Sans" -- original Helvetica is not supported by all OS
monospace = "Monospace" -- original Currier is not supported by all OS
defaultButton = "default_button"

         
-- | the SOLVER record
data Solver = Solver
    { addSpec         :: Bool -> FilePath -> Action
    -- ^ Adds a specification from file.
    , backWin         :: Action -- ^ Minimize solver window.
    , bigWin          :: Action -- ^ Bring solver window to front, even if minimized.
    , checkInSolver   :: Action
    , drawCurr        :: Action -- ^ Draw current tree.
    , forwProof       :: Action
    , showPicts       :: Action
    , stopRun         :: Action
    , buildSolve      :: Action
    -- ^ Initializes and shows the @Solver@ GUI.
    -- Main @Solver@ function that has to be called first.
    , enterPT         :: Int -> [Step] -> Action -- ^ Show pointer in textfield.
    , enterText       :: String -> Action -- ^ Show text in textfield.
    , enterFormulas   :: [TermS] -> Action -- ^ Show formulas in textfield.
    , enterTree       :: Bool -> TermS -> Action -- ^ Show tree in canvas.
    , getEntry        :: Request String -- ^ Get string from entry field.
    , getSolver       :: Request String -- ^ Returns name of this solver object.
    , getText         :: Request String -- ^ Returns content of text area.
    , getFont         :: Request FontDescription
    , getPicNo        :: Request Int
    , getSignatureR   :: Request Sig
    , getTree         :: Request (Maybe TermS)
    , iconify         :: Action -- ^ Minimize solver window.
    , isSolPos        :: Int -> Request Bool
    , labBlue         :: String -> Action
    -- ^ Shows a 'String' in the left label
    -- and set the label background to blue.
    , labRed          :: String -> Action
    -- ^ Shows a 'String' in the left label
    -- and set the label background to a pulsating red.
    , labGreen        :: String -> Action
    -- ^ Shows a 'String' in the left label
    -- and set the label background to green.
    , narrow          :: Action
    , saveGraphDP     :: Bool -> Canvas -> Int -> Action
    , setCurrInSolve  :: Int -> Action
    , setForw         :: ButtonOpts -> Action
    , setQuit         :: ButtonOpts -> Action
    -- ^ The option function sets the behavior of the forward button.
    , setInterpreter  :: String -> Action
    , setNewTrees     :: [TermS] -> String -> Action
    , setSubst        :: (String -> TermS,[String]) -> Action
    , simplify        :: Bool -> Action
    }
  
  
data Step = ApplySubst | ApplySubstTo String TermS | ApplyTransitivity | 
            BuildKripke Int | BuildRE | CollapseStep | ComposePointers |
            CopySubtrees | CreateIndHyp | CreateInvariant Bool | 
            DecomposeAtom | DeriveMode Bool Bool | EvaluateTrees | 
            ExpandTree Bool Int | FlattenImpl | Generalize [TermS] | 
            Induction Bool Int [String] | Mark [[Int]] | Match Int | Minimize |
            ModifyEqs Int | Narrow Int Bool | NegateAxioms [String] [String] |
            RandomLabels | RandomTree | ReduceRE Int | ReleaseNode |
            ReleaseSubtree | ReleaseTree | RemoveCopies | RemoveEdges Bool |
            RemoveNode | RemoveOthers | RemovePath | RemoveSubtrees |
            RenameVar String | ReplaceNodes String | ReplaceOther |
            ReplaceSubtrees [[Int]] [TermS] | ReplaceText String | 
            ReplaceVar String TermS [Int] | ReverseSubtrees | SafeEqs | 
            SetAdmitted Bool [String] | SetCurr String Int | SetDeriveMode | 
            SetMatch | ShiftPattern | ShiftQuants | ShiftSubs [[Int]] | 
            Simplify Bool Int Bool | SplitTree | StretchConclusion | 
            StretchPremise | SubsumeSubtrees | Theorem Bool TermS | 
            Transform Int | UnifySubtrees | POINTER Step
            deriving Show

data Runner = Runner
    { startRun :: Int -> Action
    , stopRun0 :: Action
    }

-- * the RUNNER templates

-- | Used by 'Ecom.runChecker'.
runner :: Action -> Template Runner
runner act = do
    runRef <- newIORef undefined
    
    return Runner
        { startRun = \millisecs -> do
            run0 <- periodic millisecs act
            writeIORef runRef run0
            runnableStart run0
        , stopRun0 = runnableStop =<< readIORef runRef
        }

-- | Used by 'Ecom.saveGraph'.
runner2 :: (Int -> Action) -> Int -> Template Runner
runner2 act bound = do
    runRef <- newIORef undefined
    nRef <- newIORef 0
    let startRun' millisecs = do
            run0 <- periodic millisecs loop
            writeIORef runRef run0
            runnableStart run0
        loop = do
            n <- readIORef nRef
            act n
            if n < bound then modifyIORef nRef succ
            else runnableStop =<< readIORef runRef
        stopRun0' = runnableStop =<< readIORef runRef
    return Runner
        { startRun = startRun'
        , stopRun0 = stopRun0'
        }

        
-- * the SWITCHER template (not used)

switcher :: Action -> Action -> Template Runner
switcher actUp actDown = do
    runRef <- newIORef undefined
    upRef  <- newIORef True
    let startRun' millisecs = do
            run0 <- periodic millisecs loop
            writeIORef runRef run0
            runnableStart run0
        loop = do
            up <- readIORef upRef
            if up then actUp else actDown
            modifyIORef upRef not
        stopRun0' = runnableStop =<< readIORef runRef
    return Runner
        { startRun = startRun'
        , stopRun0 = stopRun0'
        }
          
-- * the OSCILLATOR template (used by 'Epaint.labRed' and by 'Ecom.labRed')

oscillator :: (Int -> Action) -> (Int -> Action) -> Int -> Int -> Int
              -> Template Runner
oscillator actUp actDown lwb width upb = do
    runRef <- newIORef undefined
    valRef <- newIORef (lwb - 1)
    upRef  <- newIORef True
    
    let startRun' millisecs = do
            run0 <- periodic millisecs loop
            writeIORef runRef run0
            runnableStart run0
        loop = do
            up <- readIORef upRef
            val <- readIORef valRef
            if up then do actUp val; writeIORef valRef (val + width)
                  else do actDown val; writeIORef valRef (val-width)
            when (val < lwb || val > upb) (writeIORef upRef (not up))
        stopRun0' = runnableStop =<< readIORef runRef
    return Runner
        { startRun = startRun'
        , stopRun0 = stopRun0'
        }
              
-- * the SCANNER template (used by painter)
data Scanner = Scanner
    { startScan0 :: Int -> Picture -> Action
    , startScan  :: Int -> Action
    , addScan    :: Picture -> Action
    , stopScan0  :: Action
    , stopScan   :: Action
    , isRunning  :: Request Bool
    }

scanner :: (Widget_ -> Action) -> Template Scanner
scanner act = do
    runRef     <- newIORef undefined
    runningRef <- newIORef False
    asRef      <- newIORef []
    
    return $ let
            startScan0' delay bs = do
                writeIORef asRef bs
                startScan' delay
            startScan' delay = do
                running <- readIORef runningRef
                run <- readIORef runRef
                as <- readIORef asRef
                when running $ runnableStop run
                run0 <- periodic delay loop
                runnableStart run0
                writeIORef runRef run0
                writeIORef runningRef True
            loop = do
              as <- readIORef asRef
              case as of
                w:s -> do
                  when (noRepeat w) $ writeIORef asRef s
                  act w
                  when (isFast w) loop
                _   -> stopScan'
            stopScan0' = stopScan' >> writeIORef asRef []
            stopScan' = do
                running <- readIORef runningRef
                when running $ do
                    runnableStop =<< readIORef runRef
                    writeIORef runningRef False
        in Scanner
            { startScan0 = startScan0'
            , startScan  = startScan'
            , addScan    = \bs -> do as <- readIORef asRef
                                     writeIORef asRef $ bs ++ as
            , stopScan0  = stopScan0'
            , stopScan   = stopScan'
            , isRunning  = readIORef runningRef
            }


-- * the WIDGSTORE template (not used)

data WidgStore = WidgStore
    { saveWidg :: String -> Widget_ -> Action
    , loadWidg :: String -> Request Widget_
    }

widgStore :: Template WidgStore
widgStore = do
    storeRef <- newIORef $ const Skip
    return WidgStore
        { saveWidg = \file w -> do store <- readIORef storeRef
                                   writeIORef storeRef $ upd store file w
        , loadWidg = \file -> do
            store <- readIORef storeRef
            return $ store file
        }

-- * __Painter__ messages

combi :: Show a => a -> String
combi n = "The current combination is " ++ show n ++ "."

noPictIn :: String -> String
noPictIn file = file ++ " does not contain a picture term."

subtreesMsg :: String -> String
subtreesMsg solver = "The selected subtrees of " ++ solver ++ 
                     " have the following pictorial representations:"

treesMsg :: (Eq a, Num a, Show a, Show a1) =>
            a1 -> a -> String -> Bool -> String
treesMsg k 1 solver b =
        "A single tree has a pictorial representation. It is " ++
        ("solved and " `onlyif` b) ++ "located at position " ++ show k ++ " of "
       ++ solver ++ "."
treesMsg k n solver b =
        show n ++ " trees have pictorial representations. The one below is " ++
        ("solved and " `onlyif` b) ++ "located at position " ++ show k ++ " of "
       ++ solver ++ "."

saved :: String -> String -> String
saved "graphs" file = "The trees have been saved to " ++ file ++ "."
saved "trees" file = "The trees have been saved to " ++ file ++ "."
saved object file  = "The " ++ object ++ " has been saved to " ++ file ++ "."

savedCode :: String -> String -> String
savedCode object file = "The Haskell code of the " ++ object ++ 
                        " has been saved to " ++ file ++ "."

-- * the PAINTER template
type ButtonOpts = Button -> IORef (ConnectId Button) -> Action
type MenuOpts   = MenuItem -> IORef (ConnectId MenuItem) -> Action

data Painter = Painter
    { callPaint      :: [Picture] -> [Int] -> Bool -> Bool -> Int -> String 
                                 -> Action
    , labSolver      :: String -> Action
    , remote         :: Action
    , setButtons     :: ButtonOpts -> ButtonOpts -> ButtonOpts -> Action
    , setCurrInPaint :: Int -> Action
    , setEval        :: String -> Pos -> Action
    }

painter :: Int -> IORef Solver
        -> IORef Solver -> Template Painter
painter pheight solveRef solve2Ref = do
    builder <- loadGlade "Painter"
    let getObject :: GObjectClass cls => (GObject -> cls) -> String -> IO cls
        getObject = builderGetObject builder
        getButton = getObject castToButton
        getLabel  = getObject castToLabel
        getScale  = getObject castToScale
        
    canv <- canvas
    scrollCanv <- getObject castToScrolledWindow "scrollCanv"
    combiBut <- getButton "combiBut"
    fastBut <- getButton "fastBut"
    edgeBut <- getButton "edgeBut"
    lab <- getLabel "lab"
    modeEnt <- getObject castToEntry "modeEnt"
    narrowBut <- getButton "narrowBut"
    pictSlider <- getScale "pictSlider"
    saveEnt <- getObject castToEntry "saveEnt"
    saveDBut <- getButton "saveDBut"
    -- colorScaleSlider <- newIORef undefined
    simplifyD <- getButton "simplifyD"
    simplifyB <- getButton "simplifyB"
    spaceEnt <- getObject castToEntry "spaceEnt"
    stopBut <- getButton "stopBut"
    win <- getObject castToWindow "win"
    colorSlider <- getScale "colorSlider"
    scaleSlider <- getScale "scaleSlider"
    delaySlider <- getScale "delaySlider"
    
    narrowButSignalRef <- newIORef $ error "narrowButSignal not set"
    simplifyDSignalRef <- newIORef $ error "simplifyDSignal not set"
    simplifyBSignalRef <- newIORef $ error "simplifyBSignal not set"

    fontRef <- newIORef undefined
    
    stopButSignalRef <- newIORef $ error "undefined stopButSignalRef"
    
    -- canvSizeRef <- newIORef (0, 0)
    colorScaleRef <- newIORef (0, [])
    colsRef <- newIORef 0
    currRef <- newIORef 0
    -- delayRef <- newIORef 1
    drawModeRef <- newIORef 0
    gradeRef <- newIORef 0
    noOfGraphsRef <- newIORef 0
    spreadRef <- newIORef (0, 0)
    
    oldRscaleRef <- newIORef 1
    rscaleRef <- newIORef 1
    scaleRef <- newIORef 1
    
    arrangeModeRef <- newIORef ""
    picEvalRef <- newIORef ""
    bgcolorRef <- newIORef white
    
    changedWidgetsRef <- newIORef nil2
    oldGraphRef <- newIORef nil2
    
    fastRef <- newIORef True
    connectRef <- newIORef False
    -- onlySpaceRef <- newIORef False
    openRef <- newIORef False
    subtreesRef <- newIORef False
    isNewRef <- newIORef True
    
    edgesRef <- newIORef []
    permutationRef <- newIORef []
    picturesRef <- newIORef []
    rectIndicesRef <- newIORef []
    scansRef <- newIORef []
    solverMsgRef <- newIORef []
    treeNumbersRef <- newIORef []
    
    oldRectRef <- newIORef Nothing
    -- osciRef <- newIORef Nothing
    penposRef <- newIORef Nothing
    rectRef <- newIORef Nothing
    sourceRef <- newIORef Nothing
    targetRef <- newIORef Nothing
    bunchpictRef <- newIORef Nothing
    
    let
        addOrRemove = do
            file <- saveEnt `Gtk.get` entryText
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            let graph = (pictures!!curr,edges!!curr)
            if null file then do
                rect <- readIORef rectRef
                if isJust rect
                then do
                    writeIORef oldRectRef rect
                    writeIORef oldRscaleRef =<< readIORef rscaleRef
                    rectIndices <- readIORef rectIndicesRef
                    setCurrGraph $ removeSub graph rectIndices
                    writeIORef rectRef Nothing
                    writeIORef rectIndicesRef []
                    writeIORef rscaleRef =<< readIORef scaleRef
                    scaleAndDraw "The selection has been removed."
                else do
                    setCurrGraph nil2
                    mapM_ stopScan0 =<< readIORef scansRef
                    clear canv
                    labGreen "The graph has been removed."
            else do
                (pict',arcs') <- loadGraph file
                spread <- readIORef spreadRef
                grade <- readIORef gradeRef
                arrangeMode <- readIORef arrangeModeRef
                let f sc pict = concatGraphs spread grade arrangeMode
                                          [graph,(scalePict (1/sc) pict,arcs')]
                    msg = file ++ if null pict' then " is not a graph."
                                                else " has been added."
                rect <- readIORef rectRef
                case rect of 
                    Just r -> do
                        rscale <- readIORef rscaleRef
                        let (x,y,_,_) = widgFrame r
                            graph@(pict,_)
                                = f rscale $ map (transXY (x,y)) pict'
                        setCurrGraph graph
                        writeIORef rectIndicesRef $ getRectIndices pict rscale r
                    _ -> do
                        scale <- readIORef scaleRef
                        setCurrGraph $ f scale pict'
                scaleAndDraw msg
        
        arrangeButton graph@(pict,arcs) = do 
            mode <- modeEnt `Gtk.get` entryText
            case mode of
                "perm" -> do
                    old <- readIORef permutationRef
                    modifyIORef permutationRef nextPerm
                    arrangeMode <- readIORef arrangeModeRef
                    permutation <- readIORef permutationRef
                    setCurrGraph $ if (isTree ||| isCenter) arrangeMode 
                                   then (permuteTree old permutation,arcs)
                                   else permutePositions graph old permutation
                    scaleAndDraw "The widgets have been permuted."
                _ -> do
                    case mode of
                        x:y:r | x `elem` "amrt" -> do
                            writeIORef arrangeModeRef [x,y]
                            let colsNo = parse pnat r; angle = parse real r
                            writeIORef colsRef
                                $ fromMaybe (square pict) colsNo
                            writeIORef gradeRef
                                $ fromMaybe 0 angle
                        _ -> writeIORef arrangeModeRef mode
                    d <- spaceEnt `Gtk.get` entryText
                    arrangeMode <- readIORef arrangeModeRef
                    let dist = parse real d; x = head arrangeMode
                    when (notnull arrangeMode) $ do
                      if just dist
                        then writeIORef spreadRef $ apply2 (*(get dist)) (10,10)
                        else when (x == 'm') $ writeIORef spreadRef (0,0)
                      when (x `elem` "acmort") $ arrangeGraph False act graph
            where
                act gr = do
                    setCurrGraph gr
                    scaleAndDraw "The widgets have been arranged."
                permuteTree is ks = fold2 exchgWidgets pict ss ts
                    where (ss,ts) = unzip $ permDiff is ks
                permutePositions graph is ks = fold2 exchgPositions graph ss ts
                    where (ss,ts) = unzip $ permDiff is ks
        
        arrangeGraph noChange act graph@(pict,arcs) = do
            arrangeMode <- readIORef arrangeModeRef
            case arrangeMode of
                "o" -> act (movePict p0 pict,arcs)
                _ -> do
                    scale <- readIORef scaleRef
                    spread <- readIORef spreadRef
                    grade <- readIORef gradeRef
                    let graph1 = bunchesToArcs graph
                        graph2@(pict2,_) = scaleGraph scale graph1
                        f x = case parse nat x of 
                                Just i -> pict2!!i
                                _ -> if x == "<+>" then Skip else posWidg x
                        ws = wTreeToBunches arrangeMode spread grade
                            $ mapT (scaleWidg scale . f) $ graphToTree graph1
                        act' = act . scaleGraph (1/scale)
                    if isTree arrangeMode
                    then
                        if noChange then act graph
                        else do
                            writeIORef bunchpictRef $ Just ws
                            act' $ onlyNodes ws
                    else do
                        writeIORef bunchpictRef Nothing
                        cols <- readIORef colsRef
                        spread <- readIORef spreadRef
                        act' $ shelf graph2 cols spread 'M'
                                True True arrangeMode
        
        arrangeOrCopy = do
            rect <- readIORef rectRef
            case rect of
                Just r@(Rect _ b _) -> do
                    pictures <- readIORef picturesRef
                    curr <- readIORef currRef
                    edges <- readIORef edgesRef
                    rectIndices <- readIORef rectIndicesRef
                    scale <- readIORef scaleRef
                    rscale <- readIORef rscaleRef
                    let (pict,arcs) = (pictures!!curr,edges!!curr)
                        ms = rectIndices
                        ns = indices_ pict `minus` ms
                        lg = length pict
                        translate = transXY (2*b,0)
                        vs = [pict!!n | n <- ms]
                        ws = scalePict (rscale/scale) vs
                        pict' = fold2 updList pict ms ws
                        arcs' = foldl f arcs ns ++       -- add arcs into rect
                           map (map g . (arcs!!)) ms-- add arcs in and from rect
                        f arcs n = updList arcs n $ is++map g (ms`meet`is)
                                 where is = arcs!!n
                        g m = case search (== m) ms of Just i -> lg+i; _ -> m
                    writeIORef oldRectRef rect
                    writeIORef oldRscaleRef rscale
                    setCurrGraph (pict'++map translate vs,arcs')
                    writeIORef rectRef $ Just $ translate r
                    writeIORef rectIndicesRef [lg..lg+length ms-1]
                    scaleAndDraw "The selection has been copied."
                _ -> do
                    arrangeMode <- readIORef arrangeModeRef
                    spread <- readIORef spreadRef
                    grade <- readIORef gradeRef
                    pictures <- readIORef picturesRef
                    edges <- readIORef edgesRef
                    let graph@(pict,arcs)
                            = concatGraphs spread grade arrangeMode
                                            $ zip pictures edges
                    writeIORef picturesRef [pict]
                    writeIORef edgesRef [arcs]
                    writeIORef noOfGraphsRef 1
                    writeIORef currRef 0
                    pictSlider `Gtk.set` [widgetSensitive := False ]
                    arrangeButton graph
        
        buildPaint = do
            solve <- readIORef solveRef
            solver <- getSolver solve
            icon <- iconPixbuf
            win `Gtk.set` [ windowTitle := "Painter" ++ [last solver]
                      , windowDefaultHeight := pheight
                      , windowIcon := Just icon
                      ]
            win `on` deleteEvent $ do
                liftIO close
                return True
            
            combiBut `on` buttonActivated $ combis
            
            edgeBut `on` buttonActivated $ switchConnect
            
            fast <- readIORef fastRef
            fastBut `Gtk.set` [ buttonLabel := if fast then "slow" else "fast" ]
            fastBut `on` buttonActivated $ switchFast
            
            font <- fontDescriptionFromString $ sansSerif ++ " italic 12"
            widgetOverrideFont lab $ Just font
            
            font <- fontDescriptionFromString $ monospace ++ " 14"
            widgetOverrideFont modeEnt $ Just font
            
            let f act btn cmd = do
                    addContextClass btn defaultButton
                    setBackground btn blueback
                    writeIORef cmd =<< (btn `on` buttonActivated $ do
                        remote'
                        act
                        showPicts solve
                        )
            f (narrow solve) narrowBut narrowButSignalRef
            f (simplify solve True) simplifyD simplifyDSignalRef
            f (simplify solve False) simplifyB simplifyBSignalRef
            buildPaint1
            
        buildPaint1  = do
            solve <- readIORef solveRef
            solve2 <- readIORef solve2Ref
            solveName <- solve&getSolver
            solveName2 <- getSolver solve2
            
            closeBut <- getButton "closeBut"
            closeBut `Gtk.set` [ buttonLabel := "back to " ++ solveName]
            closeBut `on` buttonActivated $ close
            
            colorSlider `on` valueChanged $ moveColor
            colorSlider `on` buttonPressEvent $ do
                mb <- eventButton
                liftIO $ when (mb == LeftButton) pressColorScale
                return False
            colorSlider `on` buttonReleaseEvent $ do
                mb <- eventButton
                liftIO $ when (mb == LeftButton) releaseColor
                return False
            
            -- delaySlider `on` valueChanged
            --    $ writeIORef delayRef =<< delaySlider `Gtk.get` rangeValue
            delaySlider `on` buttonReleaseEvent $ do
                mb <- eventButton
                liftIO $ when (mb == LeftButton) setDelay
                return False
            modeBut <- getButton "modeBut"
            modeBut `on` buttonActivated $ arrangeOrCopy
            
            pictSlider `on` valueChanged $ do
                n <- truncate <$> pictSlider `Gtk.get` rangeValue
                writeIORef currRef n
            pictSlider `on` buttonReleaseEvent $ do
                mb <- eventButton
                when (mb == LeftButton) $ liftIO remoteDraw
                return False
            
            renewBut <- getButton "renewBut"
            renewBut `on` buttonActivated $ showPicts =<< readIORef solveRef
            resetScaleBut <- getButton "resetScaleBut"
            resetScaleBut `on` buttonActivated $ resetScale
            
            font <- fontDescriptionFromString $ monospace ++ " 14"
            widgetOverrideFont saveEnt $ Just font
            
            saveDBut `on` buttonActivated $ saveGraphD
            
            scaleSlider `on` valueChanged $ moveScale
            scaleSlider `on` buttonPressEvent $ do
                mb <- eventButton
                liftIO $ when (mb == LeftButton) pressColorScale
                return False
            scaleSlider `on` buttonReleaseEvent $ do
                mb <- eventButton
                liftIO $ when (mb == LeftButton) releaseScale
                return False
            
            solBut <- getButton "solBut"
            solBut `Gtk.set` [ buttonLabel := "show in "++ solveName2 ]
            solBut `on` buttonActivated $ showInSolver
            widgetOverrideFont spaceEnt
                =<< Just <$> fontDescriptionFromString (monospace ++ " 14")
            stopButSignal <- stopBut `on` buttonActivated $ interrupt True
            writeIORef stopButSignalRef stopButSignal
            
            undoBut <- getButton "undoBut"
            undoBut `on` buttonActivated $ undo
            
            labGreen $ combi 0
            
            -- Scroll support for canvas
            containerAdd scrollCanv $ getDrawingArea canv
            changeCanvasBackground white
            
            
            widgetShowAll win

            let drawingArea = getDrawingArea canv
            widgetAddEvents  drawingArea
                [Button1MotionMask, Button2MotionMask, Button3MotionMask]
            drawingArea `on` buttonPressEvent $ do
                p <- round2 <$> eventCoordinates
                n <- fromEnum <$> eventButton
                liftIO $ pressButton n p
                return False
            drawingArea `on` motionNotifyEvent $ do
                p <- round2 <$> eventCoordinates
                modifier <- eventModifierMouse
                let button = find (`elem` [Button1, Button2, Button3]) modifier
                liftIO $ case button of
                        Just Button1 -> moveButton 1 p
                        Just Button2 -> moveButton 2 p
                        Just Button3 -> moveButton 3 p
                        _ -> return ()
                return False
            drawingArea `on` buttonReleaseEvent $ do
                n <- fromEnum <$> eventButton
                liftIO $ releaseButton n
                return False
 
            lab `on` keyPressEvent $ do
                key <- Text.unpack <$> eventKeyName
                liftIO $ case key of
                    "p" -> mkPlanar
                    "t" -> mkTurtle
                    "u" -> unTurtle
                    _ -> return ()
                return False
            
            saveEnt `on` keyPressEvent $ do
                key <- Text.unpack <$> eventKeyName
                liftIO $ case key of
                    "Up" -> addOrRemove
                    "Down" -> saveGraph
                    _ -> return ()
                return False
            
            writeIORef isNewRef False
            resetScale
        
        callPaint' picts poss b c n str = do
            let graphs = map onlyNodes $ filter notnull picts
            when (notnull graphs) $ do
                writeIORef noOfGraphsRef $ length graphs
                write2 (picturesRef,edgesRef) $ unzip graphs
                solve <- readIORef solveRef
                writeIORef fontRef =<< getFont solve
                writeIORef treeNumbersRef poss
                writeIORef subtreesRef b
                writeIORef openRef c
                writeIORef bgcolorRef $ case parse color str of 
                                        Just col -> col; _ -> white
                noOfGraphs <- readIORef noOfGraphsRef
                modifyIORef currRef $ \curr ->
                    if b then if curr < noOfGraphs 
                    then curr else 0
                    else fromJust $ search (== n) poss`mplus`Just 0
                isNew <- readIORef isNewRef
                if isNew then buildPaint >> newPaint
                else newPaint
         where write2 (xRef, yRef) (x, y)
                    = writeIORef xRef x >> writeIORef yRef y
        
        changeCanvasBackground c@(RGB r g b) = do
            let f n = fromIntegral $ n * 256
                (r', g' , b') = (f r, f g, f b)
            canv `Gtk.set` [ canvasBackground := c ]
            widgetModifyBg scrollCanv StateNormal $ Gtk.Color r' g' b'
            
        close = do
            scans <- readIORef scansRef
            mapM_ stopScan0 scans
            clear canv
            widgetHide win
            solve <- readIORef solveRef
            bigWin solve
            stopRun solve
            checkInSolver solve
            drawCurr solve
        
        combis = do
            str <- spaceEnt `Gtk.get` entryText
            modifyIORef drawModeRef $ \drawMode -> case parse nat str of
                Just n | n < 16 -> n
                _ -> (drawMode+1) `mod` 16
            spaceEnt `Gtk.set` [ entryText :=  "" ]
            drawMode <- readIORef drawModeRef
            setBackground combiBut
                $ if drawMode == 0 then blueback else redback
            scaleAndDraw $ combi drawMode
        
        switchConnect = do 
            modifyIORef connectRef not
            connect <- readIORef connectRef
            setBackground edgeBut $ if connect then redback else blueback
        
        draw55 = drawPict . map (transXY (5,5))
        
        drawPict pict = do
            fast <- readIORef fastRef
            if fast || all isFast pict then mapM_ drawWidget pict
            else do
                scans <- readIORef scansRef
                delay <- getDelay
                let lgs = length scans
                    (picts1,picts2) = splitAt lgs picts
                    g sc pict = do
                        run <- isRunning sc
                        if run then addScan sc pict else h sc pict
                    h sc = startScan0 sc delay
                zipWithM_ g scans picts1
                when (lgp > lgs) $ do
                    scs <- replicateM (lgp - lgs) (scanner drawWidget)
                    zipWithM_ h scs picts2
                    modifyIORef scansRef $ \scans -> scans++scs
         where picts = if New `elem` pict then f pict [] [] else [pict]
               f (New:pict) picts pict' = f pict (picts++[pict']) []
               f (w:pict) picts pict'   = f pict picts (pict'++[w])
               f _ picts pict'                 = picts++[pict']
               lgp = length picts
        
        drawText (p,c,i) x = do
            bgcolor <- readIORef bgcolorRef
            let col = if deleted c then bgcolor
                      else mkLight i $ case parse colPre x of 
                                        Just (c',_) | c == black -> c'
                                        _ -> c
            font <- readIORef fontRef
            canvasText canv (round2 p)
                textOpt{ textFill = col
                       , textJustify = CenterAlign
                       , textFont = Just font
                       }
                $ delQuotes x
        
        drawTree n (F (x,q,lg) cts) ct nc c p = do
            drawText (q,nc,0) x
            drawTrees n x q lg cts ct nc c $ succsInd p cts
        drawTree _ (V (x,q,_)) _ nc _ _ = do
            drawText (q,nc,0) x
            return ()
        
        drawTrees ::
             Int
             -> String
             -> (Double, Double)
             -> Int
             -> [Term (String, (Double, Double), Int)]
             -> t
             -> Color
             -> Color
             -> [[Int]]
             -> IO ()
        drawTrees n x xy lg (ct:cts) ct0 nc c (p:ps) = do
            line canv [q,r] $ lineOpt{lineFill = c}
            drawTree n ct ct0 nc c p
            drawTrees n x xy lg cts ct0 nc c ps
            where
                (z,pz,lgz) = root ct
                v = Text_ (xy,0,black,0) n [x] [lg] 
                w = Text_ (pz,0,black,0) n [z] [lgz] 
                q = round2 $ hullCross (pz,xy) v
                r = round2 $ hullCross (xy,pz) w
        drawTrees _ _ _ _ _ _ _ _ _ = return ()
        
        drawWidget (Arc ((x,y),a,c,i) t r b) = do
            bgcolor <- readIORef bgcolorRef
            let out = outColor c i bgcolor
                fill = fillColor c i bgcolor
                arcOpt' = arcOpt{arcStyle = t, arcOutline = out}
            canvasArc canv (x, y) r (-a, b)
                $ if t == Perimeter
                  then arcOpt'{ arcWidth = r/10, arcFill = Just out}
                  else arcOpt'{arcFill = Just fill}
            return ()
        drawWidget (Fast w) = 
            if isPict w then mapM_ drawWidget $ mkPict w else drawWidget w
        drawWidget (Gif file hull) = do
            let (p,_,c,_) = getState hull
            if deleted c then drawWidget hull
            else do
                pic <- loadPhoto file
                mapM_ (canvasImage canv (round2 p) imageOpt) pic
        drawWidget (Oval ((x,y),0,c,i) rx ry) = do
            bgcolor <- readIORef bgcolorRef
            canvasOval canv (x,y) (rx,ry)
                    $ ovalOpt{ ovalOutline = outColor c i bgcolor
                             , ovalFill = Just $ fillColor c i bgcolor
                             }
            return ()
        drawWidget (Path0 c i m ps) = do
            bgcolor <- readIORef bgcolorRef
            let fill = fillColor c i bgcolor
                out = outColor c i bgcolor
                optsL :: Int -> LineOpt
                optsL 0 = lineOpt{ lineFill = out }
                optsL 1 = lineOpt{ lineFill = out, lineSmooth = True }
                optsL 2 = lineOpt{ lineFill = out, lineWidth = 2 }
                optsL _ = lineOpt{ lineFill = out
                                 , lineWidth = 2
                                 , lineSmooth = True
                                 }
                optsP :: Int -> PolygonOpt
                optsP 4 = polygonOpt{ polygonOutline = out
                                    , polygonFill = Just fill
                                    }
                optsP _ = polygonOpt{ polygonOutline = out
                                    , polygonFill = Just fill
                                    , polygonSmooth = True
                                    }
            if m < 4 then act (line canv) (optsL m)
                     else act (canvasPolygon canv) (optsP m)
            where act f opts = mapM_ (flip f opts . map round2) $ splitPath ps
                         -- do flip f opts $ map round2 ps; done
        drawWidget (Repeat w) = drawWidget w
        drawWidget Skip = return ()
        drawWidget (Text_ (p,_,c,i) n strs lgs) = zipWithM_ f [0..] strs
            where (_,_,ps) = textblock p n lgs
                  f k = drawText (ps!!k,c,i)
        drawWidget (Tree (p@(x,y),a,c,i) n c' ct) = do
            bgcolor <- readIORef bgcolorRef
            drawTree n ct' ct' (outColor c i bgcolor) c' []
            where ct' = mapT3 f ct; f (i,j) = rotate p a (i+x,j+y)
        drawWidget w | isWidg w        = drawWidget $ mkWidg w
                     | isPict w        = drawPict $ mkPict w
        drawWidget _                   = return ()
        
        getDelay = truncate <$> delaySlider `Gtk.get` rangeValue
        
        interrupt b = 
            if b then do
                scans <- readIORef scansRef
                mapM_ stopScan scans
                stopBut `Gtk.set` [ buttonLabel := "go" ]
                replaceCommandButton stopButSignalRef stopBut $ interrupt False
            else do
                delay <- getDelay
                scans <- readIORef scansRef
                mapM_ (`startScan` delay) scans 
                stopBut `Gtk.set` [ buttonLabel := "runnableStop" ]
                replaceCommandButton stopButSignalRef stopBut $ interrupt True
        
        labColor :: String -> Background -> Action
        labColor str color = do
            lab `Gtk.set` [ labelText := str ]
            setBackground lab color
        
        labGreen = flip labColor greenback
        
        labRed'   = flip labColor redpulseback
        
        labSolver' = writeIORef solverMsgRef
        
        loadGraph file = do
            str <- lookupLibs file         
            if null str then do
                solve <- readIORef solveRef
                labRed solve $ file ++ " is not a file name."
                return nil2
            else
                case parse graphString $ removeComment 0 $ str `minus1` '\n' of
                    Just graph -> return graph
                    _ -> return nil2
        
        mkPlanar = do
            n <- saveEnt `Gtk.get` entryText  
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            let maxmeet = case parse pnat n of Just n -> n; _ -> 200
                reduce = planarAll maxmeet (pictures!!curr,edges!!curr)
            rect <- readIORef rectRef
            if isJust rect then do
                rectIndices <- readIORef rectIndicesRef
                rscale <- readIORef rscaleRef
                let (graph,is) = reduce rect rectIndices rscale
                writeIORef rectIndicesRef is
                finish graph maxmeet True
            else do
                scale <- readIORef scaleRef
                finish (fst $ reduce Nothing [] scale) maxmeet False
            where
                finish graph maxmeet b = do
                  setCurrGraph graph
                  scaleAndDraw $  
                     "The " ++ (if b then "selection" else "current graph") ++
                     " has been reduced to widgets that overlap in at most " ++
                     show maxmeet ++ " pixels."
        
        mkTurtle = do
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            rect <- readIORef rectRef
            rectIndices <- readIORef rectIndicesRef
            rscale <- readIORef rscaleRef
            let (pict,arcs) = (pictures!!curr,edges!!curr)
                Rect (p@(x,y),_,_,_) b h = fromJust rect
                ks@(k:rest) = rectIndices
                w = transXY p
                    $ mkTurt (x-b,y-h) rscale $ map (pict!!) rectIndices
            if isJust rect then
                case map (pict!!) ks of
                [Turtle{}] -> labGreen "The selection is already a turtle."
                _ -> do
                    setCurrGraph $ removeSub (updList pict k w,arcs) rest
                    writeIORef rectIndicesRef [k]
                    scaleAndDraw "The selection has been turtled."
            else case pict of
                [Turtle{}] -> labGreen "The picture is already a turtle."
                _ -> do
                    scale <- readIORef scaleRef
                    setCurrGraph ([mkTurt p0 scale pict],[[]])
                    scaleAndDraw "The current graph has been turtled."
                                                   
        moveButton n p@(x,y) = do
            penpos <- readIORef penposRef
            when (isJust penpos) $ do 
                pictures <- readIORef picturesRef
                curr <- readIORef currRef
                let (x0,y0) = fromJust penpos
                    q@(x1,y1) = fromInt2 (x-x0,y-y0)
                    pict = pictures!!curr
                connect <- readIORef connectRef
                if connect then do  -- draw (smooth) arc, 
                    -- p <- adaptPos p  -- exchange nodes or move color
                    scale <- readIORef scaleRef
                    case getWidget (fromInt2 p) scale pict of
                        widget@(Just (_,w)) -> do
                            source <- readIORef sourceRef
                            if isNothing source
                            then writeIORef sourceRef widget 
                            else writeIORef targetRef widget
                            drawPict [lightWidg w]
                        _ -> return ()
                else
                    case n of                         
                        1 -> do
                            (ns,vs) <- readIORef changedWidgetsRef
                            let translate = transXY q
                                ws = map translate vs
                            writeIORef changedWidgetsRef (ns,ws)
                            rectIndices <- readIORef rectIndicesRef
                            -- move selection
                            when (ns `shares` rectIndices) $
                                modifyIORef rectRef
                                    $ Just . translate . fromJust
                        2 -> do
                            rect <- readIORef rectRef
                            when (isJust rect) $ do -- enlarge selection
                                let r@(Rect (p,_,_,_) b h) = fromJust rect
                                    r' = Rect (add2 p q,0,black,0) (b+x1) $ h+y1
                                writeIORef rectRef $ Just r'
                                setFast True
                                draw55 [delWidg r,r']
                        _ -> do
                            changedWidgets <- readIORef changedWidgetsRef
                            let (ns,vs) = changedWidgets  -- rotate widgets
                                ws = turnPict x1 vs
                            writeIORef changedWidgetsRef (ns,ws)
                            setFast True
                            rect <- readIORef rectRef
                            draw55 $ delPict vs++case rect of
                                Just r -> r:ws
                                _ -> ws
                writeIORef penposRef $ Just p

        
        moveColor = do
            n <- truncate <$> colorSlider `Gtk.get` rangeValue
            when (n /= 0) $ do
                modifyIORef colorScaleRef $ \(_, csSnd) -> (n,csSnd)
                (_,ws) <- readIORef changedWidgetsRef
                when (pictSize ws < 20) $ do
                    setFast True
                    draw55 $ map (shiftCol n) ws
        
        moveScale = do 
            n <- truncate <$> scaleSlider `Gtk.get` rangeValue
            when (n /= 0) $ do
                rect <- readIORef rectRef
                rscale <- readIORef rscaleRef
                scale <- readIORef scaleRef
                changedWidgets <- readIORef changedWidgetsRef
                colorScale <- readIORef colorScaleRef
                let sc = if isJust rect then rscale else scale
                    (_,us) = colorScale; (is,vs) = changedWidgets
                    ws = scalePict (sc+fromInt n/10*sc) us 
                writeIORef colorScaleRef (n,us)
                when (pictSize ws < 20) $ do
                    writeIORef changedWidgetsRef (is,ws)
                    setFast True
                    rect <- readIORef rectRef
                    draw55 $ delPict vs++case rect of Just r -> r:ws; _ -> ws
        
        newPaint = do
            open <- readIORef openRef
            if open then do
                solve <- readIORef solveRef
                backWin solve
                widgetShowAll win
                windowPresent  win
            else windowIconify win
            bgcolor <- readIORef bgcolorRef
            changeCanvasBackground bgcolor
            subtrees <- readIORef subtreesRef
            let back = if subtrees then redback else blueback
            setBackground narrowBut back
            setBackground simplifyD back
            setBackground simplifyB back
            stopBut `Gtk.set` [buttonLabel := "runnableStop"]
            replaceCommandButton stopButSignalRef stopBut $ interrupt True
            noOfGraphs <- readIORef noOfGraphsRef
            rangeSetRange pictSlider 0 $ fromIntegral $ noOfGraphs-1
            curr <- readIORef currRef
            pictSlider `Gtk.set` [ rangeValue := fromIntegral curr ]
            writeIORef rectRef Nothing
            writeIORef rectIndicesRef []
            writeIORef changedWidgetsRef nil2
            writeIORef gradeRef 0
            writeIORef colsRef 6
            picEval <- readIORef picEvalRef
            modeEnt  `Gtk.set`
                [entryText := if picEval == "tree" then "s" else "m16"]
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            arrangeMode <- readIORef arrangeModeRef
            spread <- readIORef spreadRef
            let graph@(pict,_) = (pictures!!curr,edges!!curr)
                mode = if isTree arrangeMode then arrangeMode else "t1"
                ws = wTreeToBunches mode spread 0 $ pictToWTree pict
                (bunch,g) = if picEval == "tree" then (Just ws,onlyNodes ws)
                                                 else (Nothing,graph)
            writeIORef bunchpictRef bunch
            arrangeGraph True act g
            where act (pict,arcs) = do
                        curr <- readIORef currRef
                        modifyIORef picturesRef $ \pictures ->
                            updList pictures curr pict
                        modifyIORef edgesRef $ \edges -> updList edges curr arcs
                        writeIORef permutationRef $ propNodes pict
                        scaleAndDraw ""

        pressButton n p = do
            scans <- readIORef scansRef
            mapM_ stopScan0 scans
            pictures <- readIORef picturesRef
            when (notnull pictures) $ do
                writeIORef penposRef $ Just p
                pictures <- readIORef picturesRef
                curr <- readIORef currRef
                edges <- readIORef edgesRef
                rectIndices <- readIORef rectIndicesRef
                let p' = fromInt2 p
                    (pict,arcs) = (pictures!!curr,edges!!curr)
                    f sc = scalePict sc $ map (pict!!) rectIndices
                connect <- readIORef connectRef
                unless connect $ case n of                         
                    1 -> do
                        rect <- readIORef rectRef
                        case rect of
                            -- move selection
                            Just r | p' `inRect` r -> do
                                rectIndices <- readIORef rectIndicesRef
                                rscale <- readIORef rscaleRef
                                writeIORef changedWidgetsRef
                                    (rectIndices,f rscale)
                                canv `Gtk.set` [ canvasCursor := Dotbox ]
                            _ -> do
                                scale <- readIORef scaleRef
                                case getWidget p' scale pict of
                                    (Just (n,w)) -> do
                                        writeIORef changedWidgetsRef ([n],[w])
                                        canv `Gtk.set` [ canvasCursor := Hand2]
                                    _ -> return ()             -- move widget
                    2 -> do
                        rect <- readIORef rectRef
                        rscale <- readIORef rscaleRef
                        writeIORef oldRectRef rect
                        writeIORef oldRscaleRef rscale
                        scale <- readIORef scaleRef
                        let pict' = fold2 updList pict rectIndices $ f 
                                                            $ rscale/scale
                        if isJust rect then do -- remove selection
                            setCurrGraph (pict',arcs) 
                            writeIORef rectRef Nothing
                            writeIORef rectIndicesRef []   
                        else do -- create selection
                            writeIORef rectRef $ Just (Rect (p',0,black,0) 0 0)
                            canv `Gtk.set` [ canvasCursor := Icon ]
                        writeIORef rscaleRef scale
                    _ -> do
                        rscale <- readIORef rscaleRef
                        rectIndices <- readIORef rectIndicesRef
                        scale <- readIORef scaleRef
                        rect <- readIORef rectRef
                        writeIORef changedWidgetsRef $ 
                            if isJust rect then (rectIndices,f rscale)
                            else (indices_ pict,scalePict scale pict)
                        canv `Gtk.set` [ canvasCursor := Exchange] -- rotate
        
        pressColorScale = do 
            scans <- readIORef scansRef
            mapM_ stopScan0 scans
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            rectIndices <- readIORef rectIndicesRef
            let pict = pictures!!curr; ws = map (pict!!) rectIndices
            rect <- readIORef rectRef
            if isJust rect then do
                rscale <- readIORef rscaleRef
                writeIORef changedWidgetsRef (rectIndices,scalePict rscale ws)
                writeIORef colorScaleRef (0,ws)
            else do
                scale <- readIORef scaleRef
                writeIORef changedWidgetsRef
                    (indices_ pict,scalePict scale pict)
                writeIORef colorScaleRef (0,pict)

        releaseButton n = do
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            let graph@(pict,arcs) = (pictures!!curr,edges!!curr)
            connect <- readIORef connectRef
            if connect then do
                source <- readIORef sourceRef
                target <- readIORef targetRef
                if isNothing source || isNothing target then nada
                else do
                    let (s,v) = fromJust source
                        (t,w) = fromJust target
                        ts = arcs!!s
                        is = getSupport graph s t; redDots = isJust is
                        connected = redDots || t `elem` ts
                        (_,_,c,i) = getState v
                        f (p,a,_,_) = (p,a,c,i)
                        w' = updState f $ pict!!t
                    case n of
                        1 -> do
                            arrangeMode <- readIORef arrangeModeRef
                            if arrangeMode == "paste"
                            then setDrawSwitch (updList pict t w',arcs)
                                                "The target has been colored."
                            else
                                if connected then setDrawSwitch 
                                    (if redDots then removeSub graph
                                        $ fromJust is
                                    else (pict,updList arcs s $ ts `minus1` t)) 
                                    "An arc has been removed."
                                else if s == t then nada
                                     else setDrawSwitch
                                            (pict,updList arcs s $ t:ts)
                                            "An arc has been drawn."
                        2 -> do
                            arrangeMode <- readIORef arrangeModeRef
                            setDrawSwitch (if (isTree ||| isCenter) arrangeMode
                                          then (exchgWidgets pict s t,arcs)
                                          else exchgPositions graph s t)
                                        "Source and target have been exchanged."
                        _ -> if s == t && isJust is ||
                             s /= t && connected && all (not . isRedDot) [v,w]
                             then nada
                             else setDrawSwitch
                                            (addSmoothArc graph (s,t,v,w,ts))
                                            "A smooth arc has been drawn."
            else do
                case n of
                    2 -> do
                        rect <- readIORef rectRef
                        case rect of
                            Just r -> do
                                rscale <- readIORef rscaleRef
                                writeIORef rectIndicesRef
                                    $ getRectIndices pict rscale r
                                rectIndices <- readIORef rectIndicesRef
                                if null rectIndices then do
                                    writeIORef rectRef Nothing
                                    nada
                                else scaleAndDraw
                                        "A subgraph has been selected."
                            _ -> scaleAndDraw "The selector has been removed."
                    _ -> do
                        rect <- readIORef rectRef
                        scale <- readIORef scaleRef
                        changedWidgets <- readIORef changedWidgetsRef
                        rscale <- readIORef rscaleRef
                        arrangeMode <- readIORef arrangeModeRef
                        let f = if isJust rect then scaleWidg $ 1/rscale
                               else transXY (-5,-5) . scaleWidg (1/scale)
                            g = fold2 updList
                            pair w i j = (g pict [i,j] [f w,pict!!i],
                                    g arcs [i,j] $ map (map h . (arcs!!)) [j,i])
                                    where h k
                                              | k == i = j
                                              | k == j = i
                                              | otherwise = k
                            graph = case changedWidgets of 
                                ([k],[w]) | isNothing rect ->
                                    case arrangeMode of 
                                        "back" -> pair w 0 k
                                        "front" -> pair w (length pict-1) k
                                        _ -> (updList pict k $ f w,arcs)
                                (ks,ws) -> (g pict ks $ map f ws,arcs)
                        setCurrGraph graph
                        scaleAndDraw "The selection has been moved or rotated."
                writeIORef penposRef Nothing
                writeIORef sourceRef Nothing
                writeIORef targetRef Nothing
                writeIORef changedWidgetsRef nil2
                canv `Gtk.set` [canvasCursor := LeftPtr]
            where nada = scaleAndDraw "Nothing can be done."
                  setDrawSwitch graph str = do
                                    setCurrGraph graph
                                    scaleAndDraw str; switchConnect
        
        releaseColor = do
            (n,_) <- readIORef colorScaleRef
            (is,_) <- readIORef changedWidgetsRef
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            let f i w = if i `elem` is then shiftCol n w else w
                (pict,arcs) = (pictures!!curr,edges!!curr)
            when (n /= 0) $ do
                setCurrGraph (zipWith f [0..] pict,arcs)
                scaleAndDraw ""
                writeIORef changedWidgetsRef nil2
                colorSlider `Gtk.set` [ rangeValue := 0 ]
        
        releaseScale = do
            mode <- modeEnt `Gtk.get` entryText
            (n,_) <- readIORef colorScaleRef
            rscale <- readIORef rscaleRef
            scale <- readIORef scaleRef
            rect <- readIORef rectRef
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            rectIndices <- readIORef rectIndicesRef
            let sc = if isJust rect then rscale+fromInt n/10*rscale 
                                     else scale+fromInt n/10*scale
                f = updState $ \(p,a,c,i) -> (apply2 (*sc) p,a,c,i)
                (pict,arcs) = (pictures!!curr,edges!!curr)
                g p i w = if i `elem` rectIndices
                          then transXY p $ f $ transXY (neg2 p) w else w
            when (n /= 0) $ do
                rect <- readIORef rectRef
                case rect of
                    Just r@(Rect (p,_,_,_) _ _) -> do
                        rscale <- readIORef rscaleRef
                        writeIORef oldRectRef rect
                        writeIORef oldRscaleRef rscale
                        if mode == "s" then do
                            writeIORef rectRef $ Just $ scaleWidg sc r
                            setCurrGraph (zipWith (g p) [0..] pict,arcs)
                        else writeIORef rscaleRef sc
                    _ | mode == "s" -> setCurrGraph (map f pict,arcs)
                      | otherwise   -> writeIORef scaleRef sc
                scaleAndDraw ""
                writeIORef changedWidgetsRef nil2
                scaleSlider `Gtk.set` [rangeValue := 0 ]
        
        remote' = do
            subtrees <- readIORef subtreesRef
            unless subtrees $ do
                treeNumbers <- readIORef treeNumbersRef
                curr <- readIORef currRef
                solve <- readIORef solveRef
                setCurrInSolve solve (treeNumbers!!curr)
        
        remoteDraw = do
          solve <- readIORef solveRef
          remote'
          drawCurr solve
          showPicts solve
        
        resetScale = do
            writeIORef oldRscaleRef 1
            writeIORef rscaleRef 1
            writeIORef scaleRef 1
        
        saveGraph = do
            pictures <- readIORef picturesRef
            if null pictures then labRed' "Enter pictures!"
            else do
                file <- saveEnt `Gtk.get` entryText
                curr <- readIORef currRef
                edges <- readIORef edgesRef
                rectIndices <- readIORef rectIndicesRef
                rscale <- readIORef rscaleRef
                filePath <- pixpath file
                usr <- userLib file
                let graph@(pict,arcs) = (pictures!!curr,edges!!curr)
                    (pict1,arcs1) = subgraph graph rectIndices
                    pict2 = scalePict rscale pict1
                    (x,y,_,_) = pictFrame pict2
                    pict3 = map (transXY (-x,-y)) pict2
                    lg = length file
                    (prefix,suffix) = splitAt (lg-4) file
                    write = writeFile usr
                    msg str = labGreen $ savedCode str usr
                    act1 = mkHtml canv prefix filePath
                    act2 n = do writeIORef currRef n
                                pictSlider `Gtk.set`
                                      [ rangeValue := fromIntegral n ]
                                remoteDraw
                                delay 100 $ act1 n
                                return ()
                if null file then labRed' "Enter a file name!"
                else do
                   if lg < 5 || suffix `notElem` words ".eps .png .gif" then do
                      rect <- readIORef rectRef
                      if just rect then
                         case pict3 of
                           [w] -> do write $ show $ updState st w; msg "widget"
                           _   -> do write $ show (pict3,arcs1); msg "selection"
                      else do
                           scale <- readIORef scaleRef
                           write $ show (scalePict scale pict,arcs)
                           msg "entire graph"
                   else case pictures of
                        [_] -> do
                               file <- savePic suffix canv filePath
                               labGreen $ saved "graph" file
                        _   -> do
                               renewDir filePath
                               saver <- runner2 act2 $ length pictures-1
                               (saver&startRun) 500
                               labGreen $ saved "graphs" $ filePath ++ ".html"
           where st (_,_,c,_) = st0 c

        saveGraphD = do
          solve <- readIORef solveRef
          str <- saveEnt `Gtk.get` entryText
          picNo <- (solve&getPicNo)
          (solve&saveGraphDP) False canv $ case parse nat str of Just n -> n
                                                                 _ -> picNo

        scaleAndDraw msg = do
            scans <- readIORef scansRef
            mapM_ stopScan0 scans
            clear canv
            sc <- scanner drawWidget
            writeIORef scansRef [sc]
            stopBut `Gtk.set` [ buttonLabel := "runnableStop" ]
            replaceCommandButton stopButSignalRef stopBut $ interrupt True
            n <- saveEnt `Gtk.get` entryText
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            drawMode <- readIORef drawModeRef
            rect <- readIORef rectRef
            rectIndices <- readIORef rectIndicesRef
            rscale <- readIORef rscaleRef
            scale <- readIORef scaleRef
            let maxmeet = case parse pnat n of Just n -> n; _ -> 200
                graph = (pictures!!curr,edges!!curr)
                reduce = planarAll maxmeet graph
                (graph',is) = if drawMode == 15 && 
                                   msg /= "A subgraph has been selected."
                              then if isJust rect 
                                   then reduce rect rectIndices rscale
                                   else reduce Nothing [] scale
                              else (graph,rectIndices)
                (pict,arcs) = bunchesToArcs graph'
                (pict1,bds) = foldr f ([],(0,0,0,0)) $ indices_ pict
                f i (ws,bds) = (w:ws,minmax4 (widgFrame w) bds)
                            where w = scaleWidg (sc i) $ pict!!i
                sc i = if i `elem` is then rscale else scale
                (x1,y1,x2,y2) = if isJust rect 
                                then minmax4 (widgFrame $ fromJust rect) bds
                                else bds
                -- Expander2: Size does not fit. Added size to avoid crop.
                sizefix = 100
                size = apply2 (max 100 . round . (+(10+sizefix))) (x2-x1,y2-y1)
                translate = transXY (-x1,-y1)
                pict2 = map translate pict1
                g = scaleWidg . recip . sc
            modifyIORef picturesRef $ \pictures ->
                updList pictures curr $ zipWith g [0..] pict2
            modifyIORef edgesRef $ \edges -> updList edges curr arcs
            canv `Gtk.set` [ canvasSize := size]
            arrangeMode <- readIORef arrangeModeRef
            treeNumbers <- readIORef treeNumbersRef
            curr <- readIORef currRef
            let pict3 = map (transXY (5,5)) pict2
                pict4 = h pict3
                h = filter propNode
                ws = if isJust rect then h $ map (pict3!!) is else pict4
                (hull,qs) = convexPath (map coords ws) pict4
                drawArrow ps = line canv (map round2 ps)
                                    $ if arrangeMode == "d1"
                                      then lineOpt{ lineSmooth = True }
                                      else lineOpt{ lineArrow = Just Last
                                                  , lineSmooth = True
                                                  }
                k = treeNumbers!!curr
            drawMode <- readIORef drawModeRef
            if drawMode `elem` [0,15] then drawPict pict3
            else case drawMode of 
                1 -> drawPict pict4
                2 -> drawPict $ h $ colorLevels True pict3 arcs
                3 -> drawPict $ h $ colorLevels False pict3 arcs
                4 -> drawPict $ pict4++hull
                5 -> do
                    font <- readIORef fontRef
                    (n,wid) <- mkSizes canv font $ map show qs
                    let addNo x p = Text_ (p,0,dark red,0) n [x] [wid x]
                    drawPict $ pict4++hull++zipWith (addNo . show) [0..] qs
                _ -> drawPict $ extendPict drawMode pict4
            when (arrangeMode /= "d2") $
                mapM_ drawArrow $ buildAndDrawPaths (pict3,arcs)
            when (isJust rect) $ do
                let (x1,y1,x2,y2) = pictFrame $ map (pict2!!) is
                    (b,h) = (abs (x2-x1)/2,abs (y2-y1)/2)
                    r = Rect ((x1+b,y1+h),0,black,0) b h
                writeIORef rectRef $ Just r
                draw55 [r]
            solve <- readIORef solveRef
            solver <- getSolver solve
            b <- isSolPos solve k
            subtrees <- readIORef subtreesRef
            noOfGraphs <- readIORef noOfGraphsRef
            let str1 = if subtrees then subtreesMsg solver
                                   else treesMsg k noOfGraphs solver b
                add str = if null str then "" else '\n':str
            solverMsg <- readIORef solverMsgRef
            labGreen $ str1 ++ add solverMsg ++ add msg

        
        setButtons' opts1 opts2 opts3 = do
            opts1 narrowBut narrowButSignalRef
            opts2 simplifyD simplifyDSignalRef
            opts3 simplifyB simplifyBSignalRef            
        
        setCurrGraph (pict,arcs) = do
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            let graph@(pict',_) = (pictures!!curr,edges!!curr)
            writeIORef oldGraphRef graph
            writeIORef picturesRef $ updList pictures curr pict
            writeIORef edgesRef $ updList edges curr arcs
            when (length pict /= length pict') $
                writeIORef permutationRef $ propNodes pict
        
        setCurrInPaint' n = do
            pictures <- readIORef picturesRef
            when (n < length pictures) $ do
                writeIORef currRef n
                pictSlider `Gtk.set` [ rangeValue := fromIntegral n ]
                scaleAndDraw ""
        
        setDelay = do 
            fast <- readIORef fastRef
            unless fast $ do
                scans <- readIORef scansRef
                runs <- mapM isRunning scans
                let scs = [scans!!i | i <- indices_ scans, runs!!i]
                if null scs then scaleAndDraw ""
                else do
                    delay <- getDelay
                    mapM_ (`startScan` delay) scs
        
        setEval' eval hv = do 
            writeIORef picEvalRef eval
            write2 (arrangeModeRef,spreadRef)
                $ case take 4 eval of 
                    "tree" -> ("t1",fromInt2 hv)
                    "over" -> ("o",(0,0))
                    _ -> ("m1",(0,0))
            where write2 (ref1, ref2) (val1, val2)
                    = writeIORef ref1 val1 >> writeIORef ref2 val2
        
        setFast b = do 
            writeIORef fastRef b
            isNew <- readIORef isNewRef
            unless isNew
                $ fastBut `Gtk.set` [ buttonLabel := if b then "slow" else "fast"]
        
        showInSolver = do
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            rect <- readIORef rectRef
            let graph = bunchesToArcs (pictures!!curr,edges!!curr)
            case rect of
                Just _ -> do
                    rscale <- readIORef rscaleRef
                    rectIndices <- readIORef rectIndicesRef
                    act $ scaleGraph rscale $ subgraph graph rectIndices
                _ -> act graph
            solve2 <- readIORef solve2Ref
            bigWin solve2
            where act graph = do
                    solve2 <- readIORef solve2Ref
                    enterTree solve2 False $ graphToTree graph
        
        switchFast = do
            fast <- readIORef fastRef
            setFast $ not fast
            scaleAndDraw ""
        
        undo = do
            drawMode <- readIORef drawModeRef
            if drawMode == 0 then do
                oldGraph <- readIORef oldGraphRef
                if null $ fst oldGraph
                then labRed' "The current graph has no predecessor."
                else do
                    oldGraph@(pict,_) <- readIORef oldGraphRef
                    setCurrGraph oldGraph
                    writeIORef rectRef =<< readIORef oldRectRef
                    writeIORef rscaleRef =<< readIORef oldRscaleRef
                    rscale <- readIORef rscaleRef
                    rect <- readIORef rectRef
                    writeIORef rectIndicesRef $
                        maybe [] (getRectIndices pict rscale) rect
                    scaleAndDraw ""
            else do
                modifyIORef drawModeRef pred
                drawMode <- readIORef drawModeRef
                when (drawMode == 0) $ setBackground combiBut blueback
                scaleAndDraw $ combi drawMode
        
        unTurtle = do
            pictures <- readIORef picturesRef
            curr <- readIORef currRef
            edges <- readIORef edgesRef
            let graph = (pictures!!curr,edges!!curr)
            rect <- readIORef rectRef
            if isJust rect 
            then do
                writeIORef oldRectRef rect
                rscale <- readIORef rscaleRef
                rectIndices <- readIORef rectIndicesRef
                let (graph',n) = unTurtG graph rscale (`elem` rectIndices)
                    k = length $ fst graph
                setCurrGraph graph'
                modifyIORef rectIndicesRef $ \rectIndices ->
                    rectIndices++[k..k+n-1]
                scaleAndDraw "The selection has been unturtled."
            else do
                scale <- readIORef scaleRef
                setCurrGraph $ fst $ unTurtG graph scale $ const True
                scaleAndDraw "The current graph has been unturtled."
           
    return Painter
        { callPaint      = callPaint'
        , labSolver      = labSolver'
        , remote         = remote'
        , setButtons     = setButtons'
        , setCurrInPaint = setCurrInPaint'
        , setEval        = setEval'
        }
-- * the GRAPH type

type Point  = (Double, Double)
type Point3 = (Double, Double, Double)
type Line_  = (Point,Point)
type Lines  = [Line_]
               
type Path  = [Point]
type State = (Point,Double,Color,Int) -- (center,orientation,hue,lightness)

-- ([w1,...,wn],[as1,...,asn]) :: Graph represents a graph with node set 
-- {w1,...,wn} and edge set {(wi,wj) | j in asi, 1 <= i,j <= n}.

data Widget_ = Arc State ArcStyleType Double Double | Bunch Widget_ [Int] |
               -- Bunch w is denotes w together with outgoing arcs to the
               -- widgets at positions is.
               Dot Color Point | Fast Widget_ | Gif String Widget_ | New |
               Oval State Double Double | Path State Int Path | 
               Path0 Color Int Int Path | Poly State Int [Double] Double |
               Rect State Double Double | Repeat Widget_ | Skip |
               Text_ State Int [String] [Int] |
               Tree State Int Color (Term (String,Point,Int)) |
               -- The center of Tree .. ct agrees with the root of ct.
               Tria State Double | Turtle State Double TurtleActs |
               WTree TermW deriving (Show,Eq)

instance Root Widget_ where undef = Skip

type TurtleActs = [TurtleAct]
data TurtleAct  = Close | Draw | 
                  -- Close and Draw finish a polygon resp. path starting at the
                  -- preceding Open command.
                   Jump Double | JumpA Double | Move Double | MoveA Double | 
                  -- JumpA and MoveA ignore the scale of the enclosing turtle.
                  Open Color Int | Scale Double | Turn Double
                    | Widg Bool Widget_
                  -- The Int parameter of Open determines the mode of the path 
                  -- ending when the next Close/Draw command is reached; 
                  -- see drawWidget (Path0 c i m ps).
                  -- Widg False w ignores the orientation of w, Widg True w 
                  -- adds it to the orientation of the enclosing turtle.
                  deriving (Show,Eq)

type Arcs      = [[Int]]
type Picture   = [Widget_]
type Graph     = (Picture,Arcs)
type TermW     = Term Widget_
type TermWP    = Term (Widget_,Point)
type WidgTrans = Widget_ -> Widget_

isWidg :: Widget_ -> Bool
isWidg Dot{}          = True    
isWidg Oval{}         = True
isWidg Path{}         = True
isWidg (Poly _ m _ _) = m < 6    
isWidg Rect{}         = True    
isWidg Tria{}         = True    
isWidg _              = False

isPict :: Widget_ -> Bool
isPict (Poly _ m _ _)     = m > 5    
isPict Turtle{}           = True
isPict _                  = False    

isWTree :: Widget_ -> Bool
isWTree (WTree _) = True
isWTree _           = False

isTree :: String -> Bool
isTree (x:_:_) = x `elem` "art"
isTree _       = False

p0 :: Point
p0 = (0,0)

st0 :: Color -> State
st0 c = (p0,0,c,0)

st0B :: State
st0B = st0 black

path0 :: Color -> Int -> Path -> Widget_
path0 = Path . st0

widg :: Widget_ -> TurtleAct
widg = Widg False

wait :: TurtleAct
wait = widg Skip

getJust :: [Maybe Picture] -> [Maybe Picture]
getJust = map f where f pict = if isJust pict then pict else Just [Skip]

noRepeat :: Widget_ -> Bool
noRepeat (Repeat _) = False
noRepeat _          = True

isFast :: Widget_ -> Bool
isFast (Fast _) = True
isFast _        = False

wfast :: Widget_ -> TurtleAct
wfast = widg . fast

fast :: Widget_ -> Widget_
fast (Turtle st sc acts) = Fast $ Turtle st sc $ map f acts
                            where f (Widg b w) = Widg b $ fast w
                                  f act        = act
fast (Bunch w is)        = Bunch (fast w) is
fast (Fast w)            = fast w
fast w                   = Fast w

posWidg :: String -> Widget_
posWidg x = Text_ st0B 0 [x] [0]

(<:>) :: TurtleAct -> [TurtleAct] -> [TurtleAct]
Move 0<:>acts            = acts
Move a<:>(Move b:acts)   = Move (a+b):acts
MoveA 0<:>acts           = acts
MoveA a<:>(MoveA b:acts) = MoveA (a+b):acts
Jump 0<:>acts            = acts
Jump a<:>(Jump b:acts)   = Jump (a+b):acts
JumpA 0<:>acts           = acts
JumpA a<:>(JumpA b:acts) = JumpA (a+b):acts
Turn 0<:>acts            = acts
Turn a<:>(Turn b:acts)   = Turn (a+b):acts
act<:>(act':acts)        = act:act'<:>acts
act<:>_                  = [act]

(<++>) :: [TurtleAct] -> [TurtleAct] -> [TurtleAct]
(act:acts)<++>acts' = act<:>acts<++>acts'
_<++>acts           = acts

reduceActs :: [TurtleAct] -> [TurtleAct]
reduceActs (act:acts) = act<:>reduceActs acts
reduceActs _          = []

turtle0 :: Color -> TurtleActs -> Widget_
turtle0 c = Turtle (st0 c) 1

turtle0B,turtle1 :: TurtleActs -> Widget_
turtle0B     = turtle0 black
turtle1 acts = (case acts of Open c _:_ -> turtle0 c
                             Widg _ w:_ -> turtle0 $ getCol w
                             _ -> turtle0B) $ reduceActs acts

up, down, back :: TurtleAct
up   = Turn $ -90
down = Turn 90
back = Turn 180

open :: TurtleAct
open = Open black 0

close2 :: [TurtleAct]
close2 = [Close,Close]

text0 :: Sizes -> String -> Widget_
text0 (n,width) x = Text_ st0B n strs $ map width strs where strs = words x

inRect :: (Double, Double) -> Widget_ -> Bool
(x',y') `inRect` Rect ((x,y),_,_,_) b h = x-b <= x' && x' <= x+b &&
                                           y-h <= y' && y' <= y+h

onlyNodes :: [a] -> ([a], Arcs)
onlyNodes pict = (pict,replicate (length pict) []::Arcs)

pictSize :: [Widget_] -> Int
pictSize = sum . map f where f (Path0 _ _ _ ps) = length ps
                             f w | isWidg w     = f $ mkWidg w
                             f w | isPict w     = pictSize $ mkPict w
                             f (Bunch w _)      = f w
                             f (Fast w)         = f w
                             f (Repeat w)       = f w
                             f _                 = 1

getPoints :: Widget_ -> Path
getPoints (Path0 _ _ _ ps) = ps
getPoints _                = error "getPoints"

getLines :: Widget_ -> Lines
getLines = mkLines . getPoints

getAllPoints :: Widget_ -> Path
getAllPoints (Bunch w _)      = getAllPoints w
getAllPoints (Fast w)         = getAllPoints w
getAllPoints (Repeat w)       = getAllPoints w
getAllPoints (Path0 _ _ _ ps) = ps
getAllPoints w | isWidg w     = getAllPoints $ mkWidg w
getAllPoints w | isPict w     = concatMap getAllPoints $ mkPict w
getAllPoints _                       = error "getAllPoints"

isTurtle :: Widget_ -> Bool
isTurtle Turtle{}       = True
isTurtle _              = False

isCenter :: String -> Bool
isCenter mode = mode == "c"

removeSub,subgraph :: Graph -> [Int] -> Graph
removeSub (pict,arcs) (i:is) = removeSub graph $ f is
                           where graph = (context i pict,map f $ context i arcs)
                                 f = foldl g []
                                 g is k
                                      | k < i = k : is
                                      | k == i = is
                                      | otherwise = (k - 1) : is
removeSub graph _ = graph
subgraph graph@(pict,_) = removeSub graph . minus (indices_ pict)
                         
center,gravity :: Widget_ -> Point
center w  = ((x1+x2)/2,(y1+y2)/2) where (x1,y1,x2,y2) = widgFrame w
gravity w = apply2 (/(fromInt $ length qs)) $ foldl1 add2 qs 
             where qs = mkSet $ getFramePts True w        
            
actsCenter :: TurtleActs -> Point
actsCenter acts = ((x1+x2)/2,(y1+y2)/2) 
                   where (x1,y1,x2,y2) = turtleFrame st0B 1 acts

jumpTo,moveTo :: Point -> TurtleActs
jumpTo (0,0) = []
jumpTo p     = [Turn a,Jump $ distance p0 p,Turn $ -a] where a = angle p0 p
moveTo (0,0) = []
moveTo p     = [Turn a,Move $ distance p0 p,Turn $ -a] where a = angle p0 p

getActs :: Widget_ -> TurtleActs
getActs Skip              = []
getActs (Turtle _ _ acts) = acts
getActs w                    = [widg w]

actsToCenter :: TurtleActs -> TurtleActs
actsToCenter acts = jumpTo (neg2 $ actsCenter acts) ++ acts

shiftWidg :: Point -> WidgTrans
shiftWidg (0,0) w = w
shiftWidg p w     = turtle0 (getCol w) $ jumpTo (neg2 p) ++ getActs w

inCenter :: WidgTrans -> WidgTrans
inCenter f w = turtle0 (getCol w') $ jumpTo p ++ [widg w'] 
               where p = gravity w
                     w' = f $ shiftWidg p w

addFrame :: Double -> Color -> Int -> Widget_ -> Widget_
addFrame n c mode w = turtle0 c $ jumpTo (neg2 p) ++ 
                               [widg $ path0 c mode $ last ps:ps] ++ getActs w
                    where (x1,y1,x2,y2) = widgFrame w
                          p = ((x1+x2)/2,(y1+y2)/2)
                          ps = [(x2d,y1d),(x2d,y2d),(x1d,y2d),(x1d,y1d)]
                          x1d = x1-n; y1d = y1-n; x2d = x2+n; y2d = y2+n

           
-- | nodeLevels b graph!!n returns the length of a shortest path from a root of 
-- graph to n. nodeLevels True counts in control points and is used by shelf
-- (see below). nodeLevels False disregards control points and is used by 
-- colorLevels (see below).
nodeLevels :: Bool -> Graph -> [Int]
nodeLevels b (pict,arcs) = iter (replicate (length nodes) 0) nodes
 where nodes = indices_ pict
       iter levels free = if null free then levels else iter levels' free'
                       where (levels',free') = f (levels,free`minus1`root) root
                             root = case searchGet g free of Just (_,m) -> m
                                                             _ -> head free
       g m = null [n | n <- nodes, m `elem` arcs!!n]
       f p i = foldl h p (arcs!!i)
             where h p@(levels,free) j = 
                     if j `notElem` free then p
                     else let k = if b && isRedDot (pict!!j) then 0 else 1
                          in f (updList levels j (levels!!i+k),free`minus1`j) j

-- | colorLevels b pict arcs colors all nodes of pict on the same level with the
-- same color.
colorLevels :: Bool -> Picture -> Arcs -> Picture
colorLevels alternate pict arcs = map f nodes
      where nodes = indices_ pict
            levels = nodeLevels False (pict,arcs)
            f n = if propNode w then updCol (g alternate $ levels!!n) w else w
                  where w = pict!!n
            g True k = if odd k then complColor c else c
            g _ k    = hue 1 c (maximum levels+1) k
            c = case searchGet (not . isBW) $ map getCol $ filter propNode pict
                          of Just (_,d) -> d; _ -> red

angle :: RealFloat a => (a,a) -> (a,a) -> a
angle (x1,y1) (x2,y2) = atan2' (y2-y1) (x2-x1)*180/pi    

atan2' :: RealFloat a => a -> a -> a
atan2' 0 0 = atan2 0 1
atan2' x y = atan2 x y

slope :: (Double, Double) -> (Double, Double) -> Double
slope (x1,y1) (x2,y2) = if x1 == x2 then fromInt maxBound else (y2-y1)/(x2-x1) 

-- successor moves on a circle.
-- successor p (distance p q) (angle p q) = q. 

successor :: Floating a => (a,a) -> a -> a -> (a,a)
successor (x,y) r a = (x+r*c,y+r*s) where (s,c) = sincos a               
                                 -- successor p 0 _ = p
                                 -- successor (x,y) r 0 = (x+r,y) 
                                 -- successor (x,y) r a = rotate (x,y) a (x+r,y)


sincos :: Floating t => t -> (t, t)
sincos a = (sin rad,cos rad) where rad = a*pi/180       -- sincos 0 = (0,1)

-- | successor2 moves on an ellipse.
successor2 :: Floating a => (a,a) -> a -> a -> a -> (a,a)
successor2 (x,y) rx ry a = (x+rx*c,y+ry*s) where (s,c) = sincos a            

distance :: Floating a => (a,a) -> (a,a) -> a
distance (x1,y1) (x2,y2) = sqrt $ (x2-x1)^2+(y2-y1)^2
                                                         
perimeter :: Path -> Double
perimeter ps = if peri <= 0 then 0.01 else peri
               where peri = sum $ zipWith distance ps $ tail ps
               
addPoints :: Path -> [Double] -> Path
addPoints ps []               = ps
addPoints (p:ps@(q:_)) (d:ds) = if d > d' then p:addPoints ps (d-d':ds)
                                 else p:addPoints (successor p d a:ps) ds
                                where d' = distance p q; a = angle p q
addPoints _ _ = error "addPoints"
                     
adaptLength :: Int -> Path -> Path
adaptLength n ps = if n > 0 then addPoints ps $ dps/2:replicate (n-1) dps
                            else ps
                   where dps = perimeter ps/k; k = fromInt n

area :: Path -> Double
area ps = abs (sum $ zipWith f ps $ tail ps++[head ps])/2
          where f (x1,y1) (x2,y2) = (x1-x2)*(y1+y2)

mindist :: (Floating a, Ord a) => (a, a) -> [(a, a)] -> (a, a)
mindist p (q:qs) = f (distance p q,q) qs
              where f dr@(d',_) (q:qs) = if d < d' then f (d,q) qs else f dr qs
                                         where d = distance p q 
                    f (_,r) _                  = r 

-- straight ps checks whether ps represents a straight line.

straight :: Path -> Bool
straight ps = and $ zipWith3 straight3 ps tps $ tail tps where tps = tail ps

straight3 :: Point -> Point -> Point -> Bool
straight3 (x1,y1) (x2,y2) (x3,y3) = x1 == x2 && x2 == x3 || 
                                     x1 /= x2 && x2 /= x3 &&
                                    (y2-y1)/(x2-x1) == (y3-y2)/(x3-x2)
             
reducePath :: Path -> Path
reducePath (p:ps@(q:r:s)) | straight3 p q r = reducePath $ p:r:s
                          | True            = p:reducePath ps
reducePath ps                               = ps     

mkLines :: Path -> Lines
mkLines ps = zip qs $ tail qs where qs = reducePath ps

-- rotate q a p rotates p clockwise by a around q on the axis (0,0,1).

rotate :: Point -> Double -> Point -> Point
rotate _ 0 p             = p         
rotate q@(i,j) a p@(x,y) = if p == q then p else (i+x1*c-y1*s,j+x1*s+y1*c)
                           where (s,c) = sincos a; x1 = x-i; y1 = y-j

-- rotateA q (a,nx,ny,nz) p rotates p clockwise by a around q on the axis
-- (nx,ny,nz).

rotateA :: Point -> Double -> Point3 -> Point -> Point
rotateA _ 0 _ p                       = p
rotateA q@(i,j) a (nx,ny,nz) p@(x,y) = if p == q then p      
                                       else (f i (c'*nx*nx+c) (c'*nx*ny-s*nz),
                                             f j (c'*nx*ny+s*nz) (c'*ny*ny+c))
                                       where (s,c) = sincos a; c' = 1-c
                                             f i a b = i+(x-i)*a+(y-j)*b

mkActs :: Picture -> [(Point,Double)] -> TurtleActs
mkActs pict = (++[Close]) . fst . fold2 f ([open],p0) pict
              where f (acts,p) w (q,a) = (acts++acts',q) 
                      where acts' = [Turn b,Jump d,Turn $ a-b,widg w,Turn $ -a]
                            b = angle p q; d = distance p q
                                             
mkTurt :: Point -> Double -> Picture -> Widget_
mkTurt p sc pict = Turtle st0B (1/sc) $ actsToCenter acts
                   where pict' = scalePict sc $ filter propNode pict
                         f = map $ coords***orient
                         acts = jumpTo (neg2 p) ++ mkActs pict' (f pict')

unTurt :: Picture -> Double -> (Int -> Bool) -> (Picture,Int)
unTurt pict sc b = (pr2***pr3) $ foldr f (length pict-1,[],0) pict
       where f w (i,pict,k) = if b i && isTurtle w 
                                   then (i-1,ws++pict,k+length ws-1)
                              else (i-1,w:pict,k)
                          where ws = scalePict (1/sc) $ mkPict $ scaleWidg sc w

unTurtG :: Graph -> Double -> (Int -> Bool) -> (Graph,Int)
unTurtG (pict,_) sc b = ((pict',replicate (length pict') []),n)
                         where (pict',n) = unTurt pict sc b

-- | getRectIndices pict sc rect returns the indices of all widgets of pict
-- within rect. getRectIndices is used by addOrRemove and releaseButton and undo
-- (see below).
getRectIndices :: Picture -> Double -> Widget_ -> [Int]
getRectIndices pict sc rect = [i | i <- indices_ scpict, 
                                    let w = scpict!!i, -- propNode w,
                                   f (coords w) || any f (getFramePts True w)]
                              where scpict = scalePict sc pict
                                    f = (`inRect` rect)

splitPath :: [a] -> [[a]]
splitPath ps = if null rs then [qs] else qs:splitPath (last qs:rs)
               where (qs,rs) = splitAt 99 ps

textblock :: (t, Double) -> Int -> [Int] -> (Double, Double, [(t, Double)])
textblock (x,y) n lgs = (fromInt (maximum lgs)/2,h,map f $ indices_ lgs) 
                        where h = m*fromInt (length lgs)
                              f i = (x,y-h+m+fromInt i*k) 
                              k = fromInt n+4; m = k/2

mkRects :: (Point, Double, Color, Int) -> Int -> Int -> Widget_
mkRects st@(p,_,_,_) n lg = Rect st b h where (b,h,_) = textblock p n [lg]

isRedDot :: Widget_ -> Bool
isRedDot (Bunch w _)           = isRedDot w
isRedDot (Dot (RGB 255 0 0) _) = True
isRedDot _                     = False

isSkip :: Widget_ -> Bool
isSkip (Bunch w _) = isSkip w
isSkip Skip        = True
isSkip _           = False

propNode :: Widget_ -> Bool
propNode = not . (isRedDot ||| isSkip)

propNodes :: [Widget_] -> [Int]
propNodes pict = [i | i <- indices_ pict, propNode $ pict!!i]

getState :: Widget_ -> State
getState (Arc st _ _ _)   = st
getState (Bunch w _)      = getState w
getState (Dot c p)        = (p,0,c,0)
getState (Fast w)         = getState w
getState (Gif _ hull)     = getState hull
getState (Oval st _ _)    = st
getState (Path st _ _)    = st
getState (Poly st _ _ _)  = st
getState (Rect st _ _)    = st
getState (Repeat w)       = getState w
getState (Text_ st _ _ _) = st
getState (Tree st _ _ _)  = st
getState (Tria st _)      = st
getState (Turtle st _ _)  = st
getState _                = st0B

coords :: Widget_ -> Point
coords w = p where (p,_,_,_) = getState w

orient :: Widget_ -> Double
orient w = a where (_,a,_,_) = getState w

getCol :: Widget_ -> Color
getCol w = c where (_,_,c,_) = getState w

filled :: Num a => Color -> a
filled c = if isBW c then 0 else 4

xcoord, ycoord :: Widget_ -> Double
xcoord = fst . coords
ycoord = snd . coords

updState :: (State -> State) -> WidgTrans 
updState f (Arc st t r a)        = Arc (f st) t r a
updState f (Bunch w is)          = Bunch (updState f w) is
updState f (Dot c p)             = Dot c' p'
  where (p',_,c',_) = f (p,0,c,0)
updState f (Fast w)              = Fast $ updState f w
updState f (Gif file hull)       = Gif file $ updState f hull
updState f (Oval st rx ry)       = Oval (f st) rx ry 
updState f (Path st m ps)        = Path (f st) m ps
updState f (Poly st m rs a)      = Poly (f st) m rs a
updState f (Rect st b h)         = Rect (f st) b h
updState f (Repeat w)            = Repeat $ updState f w
updState f (Text_ st n strs lgs) = Text_ (f st) n strs lgs
updState f (Tree st n c ct)      = Tree st' n (if d == white then white else c)
                                         ct where st'@(_,_,d,_) = f st
updState f (Tria st r)           = Tria (f st) r
updState f (Turtle st sc acts)   = Turtle (f st) sc $ map g acts
                                   where g (Open c m) = Open d m
                                                    where (_,_,d,_) = f $ st0 c
                                         g (Widg b w) = Widg b $ updState f w
                                         g act        = act
updState _ w = w

-- Each widget is turned into a picture consisting of Arcs, Dots, Gifs, 
-- horizontal or vertical Ovals, Path0s, Text_s and Trees before being drawn.

-- | mkWidg (w (p,a,c,i) ...) rotates widget w around p by a.
-- mkWidg is used by drawWidget and hulls.
mkWidg :: WidgTrans
mkWidg (Dot c p)                   = Oval (p,0,c,0) 5 5
mkWidg (Oval (p,a,c,i) rx ry)     = Path0 c i (filled c) $ map f [0,5..360]
                                    where f = rotate p a . successor2 p rx ry
mkWidg (Path (p,a,c,i) m ps)      = Path0 c i m $ map (rotate p a . add2 p) ps
mkWidg (Poly (p,a,c,i) m rs b)    = Path0 c i m $ last ps:ps
                                     where ps = circlePts p a b rs
mkWidg (Rect (p@(x,y),a,c,i) b h) = Path0 c i (filled c) $ last qs:qs
                                    where ps = [(x+b,y-h),(x+b,y+h),
                                                    (x-b,y+h),(x-b,y-h)]
                                          qs = map (rotate p a) ps
mkWidg (Tria (p@(x,y),a,c,i) r)   = Path0 c i (filled c) $ last qs:qs
                                    where ps = [(x+lg,z),(x-lg,z),(x,y-r)]
                                          lg = r*0.86602      -- r*3/(2*sqrt 3)
                                                              -- = sidelength/2
                                          z = y+lg*0.57735    -- y+lg*sqrt 3/3
                                          qs = map (rotate p a) ps

circlePts :: Point -> Double -> Double -> [Double] -> Path
circlePts p a inc = fst . foldl f ([],a)
                    where f (ps,a) 0 = (ps,a+inc)
                          f (ps,a) r = (successor p r a:ps,a+inc)

-- | mkPict is used by convexPath, hulls and drawWidget.

-- mkPict (Poly (p,a,c,i) mode rs b) with mode > 5 computes triangles or chords 
-- of a rainbow polygon with center p, orientation a, inner color c, lightness 
-- value i, radia rs and increment angle b.

-- mkPict (Turtle (p,a,c,i) sc acts) translates acts into the picture drawn by
-- a turtle that executes acts, starting out from point p with scale factor sc,
-- orientation a, color c and lightness value i.
mkPict :: Widget_ -> Picture

mkPict (Poly (p,a,c,i) m (r:rs) b) = pict
  where (pict,_,_,_,_,_) = foldl f ([],successor p r a,a+b,c,1,False) $ rs++[r]
        lg = length rs+1
        f (pict,q@(x,y),a,c,k,d) r = if r == 0 then (pict,q,a+b,c,k+1,False)
                                               else (pict++new,p',a+b,c',1,d')
          where p'@(x',y') = successor p r a
                (new, c', d')
                      | m < 9 =
                        if d then (pict', c, False) else
                          (pict', hue (m - 5) c (lg `div` 2) k, True)
                      | m < 12 = (mkPict $ w c, hue (m - 8) c lg k, d)
                      | m < 15 = (pict', hue (m - 11) c lg k, d)
                      | otherwise = (mkPict $ w $ h 1, h $ k + k, d)
                pict' = fst $ iterate g ([],q)!!k
                g (pict,q) = (pict++[Path0 c i 4 [p,q,q']],q')
                             where q' = add2 q $ apply2 (/n) (x'-x,y'-y)
                h = hue (m-14) c $ 2*lg
                n = fromInt k
                w c' = Turtle (p,0,c,i) 1 $ Turn (a-b*(n-1)/2):leafC h d c c'
                       where h = r/2; d = n*distance (h,0) (successor p0 h b)/2


mkPict (Turtle (p,a,c,i) sc acts) = 
           case foldl f iniState acts of (pict,(_,c,m,_,ps):_) -> g pict c m ps
                                         _ -> []
           where iniState = ([],[(a,c,0,sc,[p])])
                 f (pict,states@((a,c,m,sc,ps):s)) act = 
                   case act of Jump d    -> (g pict c m ps,(a,c,m,sc,[q]):s) 
                                              where q = successor p (d*sc) a
                               JumpA d   -> (g pict c m ps,(a,c,m,sc,[q]):s)
                                                where q = successor p d a
                               Move d    -> (pict,(a,c,m,sc,ps++[q]):s) 
                                              where q = successor p (d*sc) a
                               MoveA d   -> (pict,(a,c,m,sc,ps++[q]):s) 
                                              where q = successor p d a
                               Turn b    -> (pict,(a+b,c,m,sc,ps):s)
                               Open c m  -> (pict,(a,c,m,sc,[p]):states)
                               Scale sc' -> (pict,(a,c,m,sc*sc',[p]):states) 
                                            -- or ps instead of [p] ?
                               Close     -> (g pict c m ps,s)
                               Draw      -> (g pict c m ps,(a,c,m,sc,[p]):s)
                               Widg b w  -> (pict++[moveTurnScale b p a sc w],
                                             states)
                               -- _         -> (pict,states)
                   where p = last ps
                 g pict c m ps = if length ps < 2 then pict
                                 else pict++[Path0 c i m $ reducePath ps]

mkPict w = [w]

-- | inWidget is used by getWidget and scaleAndDraw (see below).
inWidget :: Point -> Widget_ -> Bool
inWidget p@(x,y) = f . coords ||| any (interior p) . getFrameLns 
                   where f (x',y') = almostEq x x' && almostEq y y'

almostEq :: (Num a, Ord a) => a -> a -> Bool
almostEq a b = abs (a-b) < 5

inFrame :: Point -> Point -> Point -> Bool
inFrame (x1,y1) (x,y) (x2,y2) = min x1 x2 `le` x && x `le` max x1 x2 &&
                                min y1 y2 `le` y && y `le` max y1 y2
                                where le a b = a < b || almostEq a b
             
onLine :: Point -> Line_ -> Bool
onLine p@(x,y) (p1@(x1,y1),p2) = inFrame p1 p p2 &&
                                  almostEq y (slope p1 p2*(x-x1)+y1)

-- | getWidget p scale pict returns a widget of pict close to p and scales it.
-- getWidget is used by selectNode (see below).
getWidget :: Point -> Double -> Picture -> Maybe (Int,Widget_)
getWidget p sc = searchGetR (not . isSkip &&& inWidget p) .
                  map (transXY (5,5) . scaleWidg sc)                        

-- |getFramePts is used by getRectIndices, gravity, morphPict, turtleFrame and 
-- widgFrame.
getFramePts :: Bool -> Widget_ -> Path
getFramePts edgy = concatMap getPoints . hulls edgy

-- | getFrameLns is used by hullCross and inWidget.
getFrameLns :: Widget_ -> [Lines]
getFrameLns = map getLines . hulls False


-- | hulls edgy w computes frame paths of w. 
-- hulls is used by dots, getFrameLns, getFramePts, extendPict, outline and
-- planarWidg.
hulls :: Bool -> Widget_ -> Picture
hulls edgy = f
 where f (Arc (p,a,c,i) t r b) = if r <= 0 then [] 
                                             else [Path0 c i (filled c) ps]
          where ps = case t of 
                    Pie   -> p:g r++[p] 
                    Chord -> last qs:qs where qs = g r
                    _     -> q:g (21*r')++reverse qs where qs@(q:_) = g $ 19*r'
                                                           r' = r/20
                g = circlePts p a (-b/36) . replicate 37
       f (Bunch w _)                          = f w
       f (Fast w)                             = f w
       f (Gif _ hull)                  = f hull
       f (Oval (p,0,c,i) rx ry)        = [Path0 c i (filled c) $
                                           map (successor2 p rx ry) [0,5..360]]
       f w@(Path0 c i m ps)            = [if edgy || even m 
                                          then w else Path0 c i m $ spline ps]
       f (Repeat w)                    = f w
       f (Text_ (p,a,c,i) n _ lgs)     = concatMap f $ zipWith g ps lgs
                                         where (_,_,ps) = textblock p n lgs
                                               g p = mkRects (p,a,c,i) n
       f (Tree (p@(x,y),a,c,i) n _ ct) = concatMap f $ foldT g $ mapT3 h ct
                         where g (_,p,lg) ss = mkRects (p,a,c,i) n lg:msum ss
                               h (i,j) = rotate p a (i+x,j+y)
       f w | isWidg w = f $ mkWidg w
           | isPict w = concatMap f $ mkPict w
       f _               = [] 
       

{- | 
    @stringsInPict@ is used by 'Ecom.showSubtreePicts' and
    'Ecom.showTreePicts'.
-}
stringsInPict :: [Widget_] -> [String]
stringsInPict = concatMap stringsInWidg

stringsInWidg :: Widget_ -> [String]
stringsInWidg (Bunch w _)        = stringsInWidg w
stringsInWidg (Fast w)                  = stringsInWidg w
stringsInWidg (Repeat w)         = stringsInWidg w
stringsInWidg (Text_ _ _ strs _) = strs
stringsInWidg (Tree _ _ _ ct)    = stringsInTree ct
stringsInWidg (Turtle _ _ acts)  = stringsInActs acts
stringsInWidg (WTree t)          = stringsInWTree t
stringsInWidg  _                   = []

stringsInWTree :: TermW -> [String]
stringsInTree :: Term (String,Point,Int) -> [String]
stringsInTree = foldT f where f (a,_,_) strs = delQuotes a:msum strs

stringsInWTree = foldT f where f w strs = stringsInWidg w++msum strs

stringsInActs :: TurtleActs -> [String]
stringsInActs = concatMap f
    where f (Widg _ w) = stringsInWidg w
          f _          = []

-- * GRAPHICAL INTERPRETERS

type InterpreterT = Sizes -> Pos -> TermS -> MaybeT Cmd Picture

jturtle :: TurtleActs -> Maybe Picture
jturtle = Just . single . turtle1

rturtle :: TurtleActs -> MaybeT Cmd Picture
rturtle = lift' . jturtle

loadWidget :: String -> Cmd Widget_
loadWidget file = do
    str <- lookupLibs file         
    if null str then return Skip
    else case parse widgString $ removeComment 0 $ str `minus1` '\n' of
        Just w -> return w
        _ -> return Skip

saveWidget :: Widget_ -> String -> Cmd ()
saveWidget w file = do
  path <- userLib file
  writeFile path $ show w

concatJust :: [Maybe [a]] -> Maybe [a]
concatJust s = do guard $ any isJust s
                  Just $ concat [as | Just as <- s]

concatJustT :: Monad m => [MaybeT m [a]] -> MaybeT m [a]
concatJustT s = MaybeT $ do s <- mapM runMaybeT s
                            return $ concatJust s

-- | searchPicT eval ... t recognizes the maximal subtrees of t that are
-- interpretable by eval and combines the resulting pictures into a single one.
searchPicT :: InterpreterT -> InterpreterT
searchPicT eval sizes spread t = g [] $ expand 0 t []
    where g p t = MaybeT $ do 
            pict <- runMaybeT (eval sizes spread t)
            if isJust pict then return pict
            else case t of 
                      F _ ts -> runMaybeT (concatJustT $ zipWithSucs g p ts)
                      _ -> return Nothing

-- | solPicT sig eval ... t recognizes the terms of a solution t that are
-- interpretable by eval and combines the resulting pictures into a single one.
solPicT :: Sig -> InterpreterT -> InterpreterT
solPicT sig eval sizes spread t = 
                     case parseSol (solAtom sig) t of
                              Just sol -> do let f = eval sizes spread . getTerm
                                             concatJustT $ map f sol
                              _ -> mzero

-- searchPicT and solPicT are used by Ecom.

partitionT :: Int -> InterpreterT
partitionT mode sizes _ t = do guard $ not $ isSum t
                               rturtle $ drawPartition sizes mode t

alignmentT,dissectionT,linearEqsT,matrixT,widgetTreeT :: InterpreterT

alignmentT sizes _ t = lift' $ do ali <- parseAlignment t
                                  jturtle $ drawAlignment sizes ali 

dissectionT _ _ (Hidden (Dissect quads)) = rturtle $ drawDissection quads
dissectionT _ _ t = lift' $ do quads <- parseList parseIntQuad t
                               jturtle $ drawDissection quads

linearEqsT sizes _ = f where
        f :: TermS -> MaybeT Cmd Picture
        f (F x [t]) | x `elem` words "bool gauss gaussI" = f t
        f t = lift' $ do eqs <- parseLinEqs t
                         jturtle $ matrixTerm sizes $ g eqs 1
        g ((poly,b):eqs) n = map h poly++(str,"=",mkConst b):g eqs (n+1)
                             where h (a,x) = (str,x,mkConst a); str = show n
        g _ _              = []

matrixT sizes spread = f where
        f :: TermS -> MaybeT Cmd Picture
        f (Hidden (BoolMat dom1 dom2 pairs@(_:_))) 
                            = rturtle $ matrixBool sizes dom1 dom2 pairs
        f (Hidden (ListMat dom1 dom2@(_:_) trips))
                            = rturtle $ matrixList sizes dom1 dom2 $ map g trips
                              where g (a,b,cs) = (a,b,map leaf cs)
        f (Hidden (ListMatL dom trips@(_:_)))
                            = rturtle $ matrixList sizes dom dom $ map g trips
                              where g (a,b,cs) = (a,b,map mkStrLPair cs)
        f t | just u         = do bins@(bin:_) <- lift' u
                                  let (arr,k,m) = karnaugh (length bin)
                                      g = binsToBinMat bins arr
                                      ts = [(show i,show j,F (g i j) [])
                                                     | i <- [1..k], j <- [1..m]]
                                  rturtle $ matrixTerm sizes ts
                               where u = parseBins t
        f (F _ [])           = mzero
        f (F "pict" ts)      = do ts <- mapM (lift' . parseConsts2Term) ts
                                  rturtle $ matrixWidget sizes spread
                                          $ deAssoc3 ts
        f (F _ ts) | just us = rturtle $ matrixBool sizes dom1 dom2 ps
                               where us = mapM parseConsts2 ts
                                     ps = deAssoc2 $ get us
                                     (dom1,dom2) = sortDoms ps
        f (F _ ts) | just us = rturtle $ matrixList sizes dom1 dom2 trs
                               where us = mapM parseConsts2Terms ts
                                     trs = deAssoc3 $ get us
                                     (dom1,dom2) = sortDoms2 trs
        f _                  = mzero

widgetTreeT sizes spread t = do t <- f [] t; return [WTree t] where
        f :: [Int] -> TermS -> MaybeT Cmd TermW
        f p (F "<+>" ts)        = do ts <- zipWithSucsM f p ts
                                     return $ F Skip ts
        f p (F "widg" ts@(_:_)) = do let u = expand 0 t $ p++[length ts-1]
                                     [w] <- widgetsT sizes spread u
                                     ts <- zipWithSucsM f p $ init ts
                                     return $ F w ts
        f p (F x ts) = do ts <- zipWithSucsM f p ts
                          return $ F (text0 sizes x) ts
        f _ (V x)    = return $ V $ if isPos x then posWidg x else text0 sizes x
        f _ _        = return $ F (text0 sizes "blue_hidden") []

widgetsT :: InterpreterT
widgetsT = widgetsCT black 

widgetsCT :: Color -> InterpreterT
widgetsCT c sizes spread (F "load" [F file []]) 
                                        = do w <- lift $ loadWidget file
                                             return [w]
widgetsCT c sizes spread (F "load" [F file [],sc]) 
                                        = do w <- lift $ loadWidget file
                                             sc <- lift' $ parseReal sc
                                             return [scaleWidg sc w]
widgetsCT c sizes spread (F "save" [t,F file []]) 
                                       = do [w] <- widgetsCT c sizes spread t
                                            lift $ saveWidget w file
                                            return [w]
widgetsCT c sizes spread t          = lift' $ widgetsC c sizes spread t

type Interpreter = Sizes -> Pos -> TermS -> Maybe Picture

widgets :: Interpreter 
widgets = widgetsC black 

widgetsM,widgetsC :: Color -> Interpreter
widgetsM c sizes spread t = do picts <- parseList' (widgetsC c sizes spread) t
                               Just $ concat picts
 
widgetsC c sizes@(n,width) spread t = f t where           

        fs  = widgetsM c sizes spread
        fs' = widgetsM (nextColor 1 (depth t) c) sizes spread
        
        f (F "$" [t,u]) | just tr       = do [w] <- fs u; Just [get tr w]
                                          where tr = widgTrans t
        f (F x [n]) | x `elem` fractals = do n <- parsePnat n
                                             jturtle $ fractal x n c
        f (F x [])  | x `elem` trunks   = Just [mkTrunk c x]
        f (F "anim" [t])      = do pict <- fs t
                                   jturtle $ init $ init $ concatMap onoff pict
        f (F "arc" [r,a])     = do r <- parseReal r; a <- parseReal a
                                   Just [Arc (st0 c) Perimeter r a]
        f (F "bar" [i,h])     = do i <- parseNat i; h <- parsePnat h
                                   guard $ i <= h; jturtle $ bar sizes n i h c
        f (F x [t]) | z == "base" = do [w] <- fs t 
                                       w' <- mkBased (notnull mode) c w
                                       Just [w']
                                    where (z,mode) = splitAt 4 x

        -- Based widgets are polygons with a horizontal line of 90 pixels 
        -- starting in (90,0) and ending in (0,0). mkBased and mkTrunk generate
        -- based widgets.

        f (F x [n,r,a]) | z == "blos"
                               = do (hue,m,n,r,a) <- blosParse x n r a mode
                                    let next1 = nextColor hue n
                                        next2 = nextColor hue $ 2*n
                                    jturtle $ if m < 4
                                              then blossom next1 n c $
                                                   case m of 
                                                        0 -> \c -> leafD r a c c
                                                        1 -> \c -> leafA r a c c
                                                        2 -> \c -> leafC r a c c
                                                        _ -> leafS r a
                                              else blossomD next2 n c $
                                                   case m of 4 -> leafD r a
                                                             5 -> leafA r a
                                                             _ -> leafC r a
                                 where (z,mode) = splitAt 4 x
        f (F "center" [t])     = do [w] <- fs t; Just [shiftWidg (center w) w]
        f (F "chord" [r,a])    = do r <- parseReal r; a <- parseReal a
                                    Just [Arc (st0 c) Chord r a]
        f (F "chordL" [h,b])   = do h <- parseReal h; b <- parseReal b
                                    jturtle $ chord True h b c
        f (F "chordR" [h,b])   = do h <- parseReal h; b <- parseReal b
                                    jturtle $ chord False h b c
        f (F "circ" [r])       = do r <- parseReal r; Just [Oval (st0 c) r r]
        f (F "colbars" [c])    = do c <- parseColor c
                                    jturtle $ colbars sizes n c
        f (F "dark" [t])       = do pict <- fs t
                                    Just $ map (shiftLight $ -16) pict
        f (F "$" [F "dots" [n],t]) = do n <- parsePnat n; pict <- fs t
                                        Just $ dots n pict
        f (F "fadeB" [t])      = do [w] <- fs t; jturtle $ fade False w
        f (F "fadeW" [t])      = do [w] <- fs t; jturtle $ fade True w
        f (F "fast" [t])       = do pict <- fs t; Just $ map fast pict
        f (F "flash" [t])      = do [w] <- fs t; jturtle $ flash w
        f (F "fern2" [n,d,r])  = do n <- parsePnat n; d <- parseReal d
                                    r <- parseReal r; jturtle $ fern2 n c d r
        f (F "flipH" [t])      = do pict <- fs t; Just $ flipPict True pict
        f (F "flipV" [t])      = do pict <- fs t; Just $ flipPict False pict
        f (F "$" [F "flower" [mode],u])
                               = do pict <- fs' t; mode <- parseNat mode
                                    jturtle $ flower c mode pict
        f (F "fork" [t])       = do pict <- fs t; guard $ all isTurtle pict
                                    jturtle $ tail $ concatMap h pict
                                 where h (Turtle _ _ as) = widg New:as
                                       h _               = []
        f (F x [t]) | z == "frame"  = do pict <- fs t
                                         mode <- search (== mode) pathmodes
                                         Just $ map (addFrame 5 c mode) pict
                                      where (z,mode) = splitAt 5 x
        f (F "gif" [F file [],b,h]) = do b <- parseReal b; h <- parseReal h
                                         Just [Gif file $ Rect (st0 c) b h]
        f (F "gifs" [d,n,b,h]) = do d <- parseConst d; n <- parsePnat n
                                    b <- parseReal b; h <- parseReal h
                                    let str i = d </> (d ++ '_':show i)
                                        gif i = Gif (str i) $ Rect (st0 c) b h
                                    Just $ map gif [1..n]
        f (F "grav" [t])       = do [w] <- fs t; Just [shiftWidg (gravity w) w]
        f (F "$" [F "grow" [t],u])    = do [w] <- fs t; pict <- fs' u
                                           jturtle $ grow id (updCol c w) 
                                                   $ map getActs pict
        f (F "$" [F "growT" [t,u],v]) = do tr <- widgTrans t; [w] <- fs u
                                           pict <- fs' v
                                           jturtle $ grow tr (updCol c w) 
                                                   $ map getActs pict
        f (F x [n]) | z == "hilbP"    = do mode <- search (== mode) pathmodes
                                           n <- parsePnat n
                                           Just [turtle0 c $ hilbert n East]
                                        where (z,mode) = splitAt 5 x
        f (F x [t]) | z == "hue"     
                               = do acts <- parseActs t
                                    hue <- search (== hue) huemodes
                                    let acts' = mkHue (nextColor $ hue+1) c acts
                                    Just [turtle0 c acts']
                                 where (z,hue) = splitAt 3 x
        f (F x [t]) | z == "join" 
                               = do mode <- parse pnat mode
                                    guard $ mode `elem` [6..14]; pict <- fs t
                                    Just [mkTurt p0 1 $ extendPict mode pict]
                                 where (z,mode) = splitAt 4 x
        f (F x [r,a]) | y == "leaf" 
                               = do m <- search (== mode) leafmodes
                                    r <- parseReal r; a <- parseReal a
                                    let c' = complColor c
                                    jturtle $ case m of 0 -> leafD r a c c
                                                        1 -> leafA r a c c
                                                        2 -> leafC r a c c
                                                        3 -> leafS r a c
                                                        4 -> leafD r a c c'
                                                        5 -> leafA r a c c'
                                                        _ -> leafC r a c c'
                                 where (y,mode) = splitAt 4 x
        f (F "light" [t])      = do pict <- fs t
                                    Just $ map (shiftLight 21) pict
        f (F "$" [F x [n],t]) | z == "morph"
                               = do hue:mode <- Just mode
                                    hue <- parse nat [hue]
                                    guard $ hue `elem` [1,2,3]
                                    mode <- search (== mode) pathmodes
                                    n <- parsePnat n; pict <- fs t
                                    Just $ morphPict mode hue n pict 
                                 where (z,mode) = splitAt 5 x
        f (F "new" [])         = Just [New]
        f (F "oleaf" [n])      = do n <- parsePnat n; jturtle $ oleaf n c
        f (F x [n,d,m]) | z == "owave" 
                               = do mode <- search (== mode) pathmodes
                                    n <- parsePnat n; d <- parseReal d
                                    m <- parseInt m
                                    jturtle $ owave mode n d m c
                                 where (z,mode) = splitAt 5 x
        f (F "outline" [t])    = do pict <- fs t; Just $ outline pict
        f (F "oval" [rx,ry])   = do rx <- parseReal rx; ry <- parseReal ry
                                    Just [Oval (st0 c) rx ry]
        f (F x [t]) | z == "path"
                               = do mode <- search (== mode) pathmodes
                                    ps <- parseList parseRealReal t
                                    Just [path0 c mode ps]
                                 where (z,mode) = splitAt 4 x
        {- f (F x ps) | z == "path"
                               = do mode <- search (== mode) pathmodes
                                    ps@((x,y):_) <- mapM parseRealReal ps
                                    let h (i,j) = (i-x,j-y)
                                    Just [path0 c mode $ map h ps]
                                 where (z,mode) = splitAt 4 x -}
        f (F x rs@(_:_)) | z == "peaks"
                               = do m:mode <- Just mode
                                    mode <- search (== mode) polymodes
                                    rs <- mapM parseReal rs
                                    guard $ head rs /= 0
                                    jturtle $ peaks (m == 'I') mode c rs
                                 where (z,mode) = splitAt 5 x
        f (F x (n:rs@(_:_))) | z == "pie"
                               = do mode:hue <- Just mode
                                    let m = case mode of 'A' -> Perimeter
                                                         'C' -> Chord
                                                         _ -> Pie
                                    hue <- search (== hue) huemodes
                                    n <- parsePnat n; rs <- mapM parseReal rs
                                    jturtle $ pie m (nextColor $ hue+1) c 
                                            $ concat $ replicate n rs
                                  where (z,mode) = splitAt 3 x
        f (F "pile" [h,i])     = do h <- parsePnat h; i <- parseNat i
                                    guard $ i <= h; jturtle $ pile h i
        f (F "pileR" [t])      = do h:is <- parseList parseNat t
                                    guard $ all (< h) is; jturtle $ pileR h is
        f (F "$" [F "place" [t],p]) = do [w] <- fs t; p <- parseRealReal p
                                         jturtle $ jumpTo p ++ [widg w]
        f (F x [n,d,m]) | z == "plait" 
                               = do mode <- search (== mode) pathmodes
                                    n <- parsePnat n; d <- parseReal d
                                    m <- parsePnat m
                                    jturtle $ plait mode n d m c
                                 where (z,mode) = splitAt 5 x
        f (F "$" [F "planar" [n],t])   
                               = do maxmeet <- parsePnat n; [w] <- fs t
                                    Just [planarWidg maxmeet w]
        f (F x (n:rs@(_:_))) | z == "poly"
                               = do mode <- search (== mode) polymodes
                                    n <- parsePnat n; rs <- mapM parseReal rs
                                    let k = n*length rs; inc = 360/fromInt k
                                    guard $ k > 1
                                    Just [Poly (st0 c) mode 
                                               (take k $ cycle rs) inc] 
                                 where (z,mode) = splitAt 4 x
        f (F "pulse" [t])      = do pict <- fs t; jturtle $ pulse pict
        f (F "rect" [b,h])     = do b <- parseReal b; h <- parseReal h
                                    Just [Rect (st0 c) b h]
        f (F "repeat" [t])     = do pict <- fs t
                                    Just [Repeat $ turtle0B $ map widg pict]
        f (F "revpic" [t])     = do pict <- fs t; Just $ reverse pict
        f (F "rhomb" [])       = Just [rhombV c]
        f (F "$" [F "rotate" [a],t])
                               = do a <- parseReal a; guard $ a /= 0
                                    pict <- fs t; jturtle $ rotatePict a pict
        f (F "$" [F "scale" [sc],t]) 
                               = do sc <- parseReal sc; pict <- fs t
                                    Just $ scalePict sc pict
        f (F "$" [F x (n:s),t]) | x `elem` ["shelf","tower","shelfS","towerS"]
                           = do n <- parsePnat n
                                pict <- fs t
                                let k = if last x == 'S' then square pict else n
                                    c = if take 5 x == "shelf" then '1' else '2'
                                    h d a b = Just $ fst $ shelf (pict,[]) k 
                                                         (d,d) a b False ['m',c]
                                case s of 
                                     d:s -> do
                                            d <- parseReal d        -- spacing
                                            case s of 
                                             a:s -> do
                                                   a <- parseChar a -- alignment
                                                   case s of        -- centering
                                                     b:s -> do
                                                          b <- parseChar b
                                                          h d a $ b == 'C'
                                                     _ -> h d a False
                                             _ -> h d 'M' False
                                     _ -> h 0 'M' False
        f (F "skip" [])        = Just [Skip]
        f (F "slice" [r,a])    = do r <- parseReal r; a <- parseReal a
                                    Just [Arc (st0 c) Pie r a]
        f (F "smooth" [t])     = do pict <- fs t; Just $ smooth pict
        f (F x [d,m,n,k,t]) | z == "snow"
                               = do hue <- search (== mode) huemodes
                                    d <- parseReal d; m <- parsePnat m
                                    n <- parsePnat n; k <- parsePnat k
                                    [w] <- fs t
                                    Just [mkSnow True (hue+1) d m n k w]
                                 where (z,mode) = splitAt 4 x
        f (F "spline" [t])     = do pict <- fs t; Just $ splinePict pict
        f (F "star" [n,r,r'])  = do n <- parsePnat n; r <- parseReal r
                                    r' <- parseReal r'; jturtle $ star n c r r'
        f (F "$" [F "table" [n,d],t]) 
                               = do n <- parsePnat n; d <- parseReal d
                                    pict <- fs t; Just [table pict d n]
        f (F "taichi" s)       = jturtle $ taichi sizes s c
        f (F "text" ts)        = do guard $ notnull strs
                                    Just [Text_ (st0 c) n strs $ map width strs]
                                 where strs = map (map h) $ words $ showTree
                                              False $ colHidden $ mkTup ts
                                       h x = if x == '\'' then ' ' else x
        f (F "tree" [t])       = Just [Tree st0B n c $ mapT h ct]
                                 where ct = coordTree width spread 
                                                      (20,20) $ colHidden t
                                       (_,(x,y)) = root ct
                                       h (a,(i,j)) = (a,fromInt2 (i-x,j-y),
                                                      width a)
        f (F "tria" [r])       = do r <- parseReal r; Just [Tria (st0 c) r]
        f (F "$" [F "turn" [a],t])    
                               = do a <- parseReal a; pict <- fs t
                                    Just $ turnPict a pict
        f (F "turt" [t])       = do acts <- parseActs t
                                    Just [turtle0 c acts]
        f (F x [n,d,a]) | z == "wave"
                               = do mode <- search (== mode) pathmodes
                                    n <- parsePnat n; d <- parseReal d
                                    a <- parseReal a
                                    jturtle $ wave mode n d a c
                                 where (z,mode) = splitAt 4 x
        f (F x [t]) | just c   = widgetsC (get c) sizes spread t
                                 where c = parse color x
        f _                    = Nothing
         
        parseActs,g :: TermS -> Maybe TurtleActs
        parseActs t       = do acts <- parseList' g t; Just $ concat acts
        g (V x) | isPos x = g $ getSubterm t $ getPos x
        g (F "A" [t])     = widgAct True t
        g (F "B" [])      = Just [back]
        g (F "C" [])      = Just [Close]
        g (F "D" [])      = Just [Draw]
        g (F "J" [d])     = do d <- parseReal d; Just [Jump d]
        g (F "J" p@[x,y]) = do [x,y] <- mapM parseReal p; Just $ jumpTo (x,y) 
        g (F "L" [])      = Just [up]
        g (F "M" [d])     = do d <- parseReal d; Just [Move d]
        g (F "M" p@[x,y]) = do [x,y] <- mapM parseReal p; Just $ moveTo (x,y) 
        g (F "O" [])      = Just [Open c 0]
        g (F "O" [c])     = do c <- parseColor c; Just [Open c 0]
        g (F "OS" [])     = Just [Open c 1]
        g (F "OS" [c])    = do c <- parseColor c; Just [Open c 1]
        g (F "OF" [])     = Just [Open c 2]
        g (F "OFS" [])    = Just [Open c 3]
        g (F "OF" [c])    = do c <- parseColor c; Just [Open c 4]
        g (F "OFS" [c])   = do c <- parseColor c; Just [Open c 5]
        g (F "R" [])      = Just [down]
        g (F "SC" [sc])   = do sc <- parseReal sc; Just [Scale sc]
        g (F "T" [a])     = do a <- parseReal a; Just [Turn a]
        g t               = widgAct False t

        widgAct :: Bool -> TermS -> Maybe TurtleActs
        widgAct b t = do [w] <- fs t ++ Just [text0 sizes $ showTerm0 t]
                         Just [Widg b w]
  
huemodes   = "":words "2 3 4 5 6"
pathmodes  = "":words "S W SW F SF"
polymodes  = pathmodes ++ words "R R1 R2 L L1 L2 T T1 T2 LT LT1 LT2"
trackmodes = words "asc sym ang slo"
leafmodes  = words "D A C S D2 A2 C2"

fractals = words "bush bush2 cant cactus dragon fern gras grasL grasA grasC" ++
           words "grasR hexa hilb koch penta pentaS pytree pytreeA wide"
trunks   = words "TR SQ PE PY CA HE LB RB LS RS PS"

depth (F "$" [F "flower" _,t]) = depth t+1
depth (F "$" [F "grow" _,t])   = depth t+1
depth (F "$" [F "growT" _,t])  = depth t+1
depth (F _ ts)                 = maximum $ 1:map depth ts
depth _                        = 1

-- The following widget transformations may occur as arguments of growT (see 
-- widgets). They do not modify the outline of a widget and can thus be applied 
-- to based widgets. 

widgTrans :: TermS -> Maybe WidgTrans
widgTrans t = f t where
    f (F "." [t,u])           = do tr1 <- widgTrans t; tr2 <- widgTrans u
                                   Just $ tr1 . tr2
    f (F x [F mode []]) | init z == "trac" 
                              = do guard $ typ `elem` trackmodes
                                   m <- search (== m) pathmodes 
                                   hue <- search (== hue) huemodes
                                   let center = if last z == 'c' then coords
                                                                 else gravity
                                   Just $ track center typ m $ nextColor $ hue+1
                                where (z,hue) = splitAt 5 x
                                      (typ,m) = splitAt 3 mode
    f (F x (n:s)) | z == "rainbow" 
                              = do n <- parsePnat n
                                   hue <- search (== hue) huemodes
                                   let next = nextColor (hue+1) n
                                   if null s then Just $ rainbow n 0 0 next
                                   else do
                                        [a,d] <- mapM parseReal s
                                        Just $ rainbow n a d next
                                where (z,hue) = splitAt 7 x
    f (F "shine" (i:s))       = do i <- parseInt i
                                   guard $ abs i `elem` [1..42]
                                   if null s then Just $ shine i 0 0
                                             else do
                                                  [a,d] <- mapM parseReal s
                                                  Just $ shine i a d
    f (F "inCenter" [tr])     = do tr <- widgTrans tr; Just $ inCenter tr
    f _                       = Nothing


-- | wTreeToBunches is used by 'arrangeGraph', 'concatGraphs' and 'newPaint'
wTreeToBunches :: String -> Point -> Double -> TermW -> Picture
wTreeToBunches mode (hor,ver) grade t = w:ws2
  where w:ws = bunches (if head mode == 'a' then chgY 0 ct else ct) pt
        ct = F (v,p0) $ subterms $ transTree2 (-x,-y) ct0
        (pt,_) = preordTerm black (const id) t0
        (v,(x,y)) = root ct0
        ct0 = coordWTree (hor,ver0) (20,20) t0
        (t0,ver0) = if mode `elem` words "t2 a2 r5 r6 r7 r8"
                    then (mapT (chgPoss $ isSkip $ root t) $ addControls t,
                          ver/2) 
                    else (t,ver)
        chgPoss b (Text_ _ _ [x] _) | isPos x 
                     = posWidg $ "pos "++unwords (map show q)
                       where p = concatMap (\n->[n,0]) $ getPos x
                             q = if b then context 1 p else p
        chgPoss _ w = w
        addControls (F w ts) = F w (map h ts)
                               where h = if isSkip w then addControls else g
                                     g t@(V (Text_ _ _ [x] _)) | isPos x = t
                                     g t = F (Dot red p0) [addControls t]
        addControls t              = t
        bunches :: TermWP -> Term Int -> Picture
        bunches (F (w,p) cts) (F _ pts) = Bunch (moveWidg p w) (map root pts):
                                          msum (zipWith bunches cts pts)
        bunches (V (Text_ _ _ [x] _,p)) _ | isPos x 
                                         = [Bunch (Dot red p) [root t]]
                                          where t = getSubterm pt $ getPos x
        bunches (V (w,p)) _             = [Bunch (moveWidg p w) []]
        chgY i (F (w,(x,_)) cts) = F (w,(x,vshift!!i)) $ map (chgY (i+1)) cts
        chgY i (V (w,(x,_)))     = V (w,(x,vshift!!i))
        vshift = shiftW maxminy ver0 $ map f [0..height ct-1]
        f = (widgFrame *** ycoord) . turtle0B . map (Widg True) . row
        row n = zipWith moveWidg ps ws
            where (ws,ps) = unzip [label ct p | p <- allPoss ct, length p == n]
        [h,c] = mode; n = parse pnat [c]; m = fromJust n
        p@(xp,_) = coords w
        ws1 = if h == 'r' && isJust n && m `elem` [1..8] then map (rot m) ws 
                                                         else ws
        ws2 = if grade == 0 then ws1 else map rotAll ws1
        rot 1 v = moveWidg (rotate p (grad1 z) (xp,y)) v where (z,y) = coords v
        rot 2 v = moveTurn True (rotate p a (xp,y)) a v  where (z,y) = coords v
                                                               a = grad1 z
        rot 3 v = moveWidg (rotate p (grad2 v y) (xp,y)) v where y = ycoord v
        rot 4 v = moveTurn True (rotate p a (xp,y)) a v    where y = ycoord v
                                                                 a = grad2 v y
        rot m v = rot (m-4) v
        rotAll v = moveWidg (rotate p grade $ coords v) v
                -- moveTurn True (...) grade v
        left = op (-); right = op (+); op f w = f (xcoord w) $ midx w
        (minw,maxw) = foldl f (w,w) ws
              where f uv@(u, v) w
                          | left w < left u = (w, v)
                          | right w > right v = (u, w)
                          | otherwise = uv
        minx = left minw-hor/2; maxx = right maxw+hor/2
        grad1 z = case gauss eqs of 
                       Just eqs | all g eqs 
                         -> let [a,b,c] = map snd (sort (<) eqs) in a*z*z+b*z+c
                       _ -> error "gauss"
                  where g ([(1,_)],_) = True; g _ = False; c = (1,"c")
                        eqs = [([(minx*minx,"a"),(minx,"b"),c],xp-180),
                               ([(xp*xp,"a"),(xp,"b"),c],xp),
                               ([(maxx*maxx,"a"),(maxx,"b"),c],xp+180)]
        grad2 v y = 360*fromInt (getInd v vs)/fromInt (length vs)
                    where vs = sort rel [w | w <- ws, y == ycoord w]
                          rel v w = xcoord v > xcoord w

shiftW :: Num a => ((t, t) -> (a, a)) -> a -> [(t, a)] -> [a]
shiftW maxmin d (x:xs) = fst $ foldl f ([0],x) xs
      where f (s,(fv,cv)) w@(fw,cw) = (s++[last s+abs (rv-cv)+d+abs (cw-lw)],w) 
                                      where (rv,lw) = maxmin (fv,fw)

maxminx :: ((a, b, c, d), (e, f, g, h)) -> (c, e)
maxminx ((_,_,xv,_),(xw,_,_,_)) = (xv,xw)
maxminy :: ((a, b, c, d), (e, f, g, h)) -> (d, f)
maxminy ((_,_,_,yv),(_,yw,_,_)) = (yv,yw)

midx,midy :: Widget_ -> Double
midx w = (x'-x)/2 where (x,_,x',_) = widgFrame w
midy w = (y'-y)/2 where (_,y,_,y') = widgFrame w

-- | coordWTree (hor,ver) p t adds coordinates to the nodes of t such that p is 
-- the leftmost-uppermost corner of the smallest rectangle enclosing t.
-- hor is the horizontal space between adjacent subtrees. ver is the vertical 
-- space between adjacent tree levels.
coordWTree :: Point -> Point -> Term Widget_ -> TermWP
coordWTree (hor,ver) p = alignWLeaves hor . f p
  where f (x,y) (V w)    = V (w,(x+midx w,y))
        f (x,y) (F w []) = F (w,(x+midx w,y)) []
        f (x,y) (F w ts) = if bdiff <= 0 then ct' else transTree1 (bdiff/2) ct'
                     where bdiff = midx w-foldT h ct+x
                           hdiff = height w+maximum (map (height . root) ts)
                           height w = y'-y where (_,y,_,y') = widgFrame w
                           ct:cts = map (f (x,y+hdiff/2+ver)) ts
                           cts' = transWTrees hor ct cts
                           ct' = F (w,((g (head cts')+g (last cts'))/2,y)) cts'
                           g = fst . snd . root
                           h (w,(x,_)) = maximum . ((x+midx w):)

-- transWTrees hor ct cts orders the trees of ct:cts with a horizontal space of 
-- hor units between adjacent trees. transTrees takes into account different 
-- heights of adjacent trees by shifting them to the left or to the right such 
-- that nodes on low levels of a tree may occur below a neighbour with fewer 
-- levels.
transWTrees :: Double -> TermWP -> [TermWP] -> [TermWP]
transWTrees hor ct = f [ct]
      where f us (t:ts) = if d < 0 then f (map (transTree1 $ -d) us++[t]) ts
                          else f (us++[transTree1 d t]) $ map (transTree1 d) ts
                       -- f (us++[if d < 0 then t else transTree1 d t]) ts
                          where d = maximum (map h us)+hor
                                h u = f (+) maximum u-f (-) minimum t
                                      where f = g $ min (height t) $ height u
            f us _      = us
            g _ op _ (V (w,(x,_)))    = h op w x
            g 1 op _ (F (w,(x,_)) _)  = h op w x
            g n op m (F (w,(x,_)) ts) = m $ h op w x:map (g (n-1) op m) ts
            h op w x = op x $ midx w

-- | @alignWLeaves t@ replaces the leaves of @t@ such that all gaps between
-- neighbours become equal.
alignWLeaves :: Double -> TermWP -> TermWP
alignWLeaves hor (F a ts) = F a $ equalWGaps hor $ map (alignWLeaves hor) ts 
alignWLeaves _ t            = t        

equalWGaps :: Double -> [TermWP] -> [TermWP]
equalWGaps hor ts = if length ts > 2 then us++vs else ts
                   where (us,vs) = foldl f ([],[head ts]) $ tail ts
                         f (us,vs) v = if isWLeaf v then (us,vs++[v])
                                        else (us++transWLeaves hor vs v,[v])

isWLeaf :: TermWP -> Bool
isWLeaf (V _)    = True
isWLeaf (F _ []) = True
isWLeaf _        = False

transWLeaves :: Double -> [TermWP] -> TermWP -> [TermWP]
transWLeaves hor ts t = loop hor
              where loop hor = if x1+w1+hor >= x2-w2 then us else loop $ hor+1 
                         where us = transWTrees hor (head ts) $ tail ts
                               [x1,x2] = map (fst . snd . root) [last us,t]
                               [w1,w2] = map (midx . fst . root) [last us,t]


-- | graphToTree is used by 'arrangeGraph' and 'showInSolver'.
graphToTree :: Graph -> TermS
graphToTree graph = eqsToGraph [] eqs
   where (eqs,_) = relToEqs 0 $ map f $ propNodes $ fst graph
         f i = (show i,[show $ last path | k:path <- buildPaths graph, k == i])

-- * __Morphing__, __scaling__ and __framing__

morphPict :: Int -> Int -> Int -> Picture -> Picture
morphPict mode m n ws = msum $ zipWith f (init ws) $ tail ws
 where f v w = map g [0..n-1]
               where [ps,qs] = map (getFramePts False) [v,w]
                     diff = length ps-length qs
                     ps' = adaptLength (-diff) ps
                     qs' = adaptLength diff qs
                     g i = path0 (hue m (getCol v) n i) mode $ 
                                       zipWith morph ps' qs'
                          where morph (xv,yv) (xw,yw) = (next xv xw,next yv yw)
                                next x z = (1-inc)*x+inc*z
                                inc = fromInt i/fromInt n

scaleGraph :: Double -> Graph -> Graph
scaleGraph sc (pict,arcs) = (scalePict sc pict,arcs)

scalePict :: Double -> Picture -> Picture
scalePict 1  = id
scalePict sc = map $ scaleWidg sc

-- | scaleWidg sc w scales w by multiplying its vertices/radia with sc. 
-- Dots, gifs and texts are not scaled. 
scaleWidg :: Double -> Widget_ -> Widget_
scaleWidg 1  w                    = w
scaleWidg sc (Arc st t r a)       = Arc st t (r*sc) a
scaleWidg sc (Bunch w is)         = Bunch (scaleWidg sc w) is
scaleWidg sc (Fast w)             = Fast $ scaleWidg sc w
scaleWidg sc (Oval st rx ry)      = Oval st (rx*sc) $ ry*sc
scaleWidg sc (Path st n ps)       = Path st n $ map (apply2 (*sc)) ps
scaleWidg sc (Poly st n rs a)     = Poly st n (map (*sc) rs) a 
scaleWidg sc (Rect st b h)        = Rect st (b*sc) $ h*sc
scaleWidg sc (Repeat w)           = Repeat $ scaleWidg sc w
scaleWidg sc (Tree st n c ct)     = Tree st n c $ mapT3 (apply2 (*sc)) ct
scaleWidg sc (Tria st r)          = Tria st $ r*sc
scaleWidg sc (Turtle st sc' acts) = Turtle st (sc*sc') acts
scaleWidg _ w                            = w

pictFrame :: [Widget_] -> (Double, Double, Double, Double)
pictFrame pict = foldl f (0,0,0,0) $ indices_ pict
                 where f bds = minmax4 bds . widgFrame . (pict!!)

-- | widgFrame w returns the leftmost-uppermost and rightmost-lowermost
-- coordinates of the smallest rectangle that encloses w. widgFrame is used by
-- scaleAndDraw (see above), addFrame and shelf (see below).
widgFrame :: Widget_ -> (Double, Double, Double, Double)
widgFrame (Turtle st sc acts) = turtleFrame st sc acts
widgFrame w                   = minmax $ coords w:getFramePts True w

turtleFrame :: ((Double, Double), Double, a, b)
            -> Double -> [TurtleAct] -> (Double, Double, Double, Double)
turtleFrame (p,a,_,_) sc acts = minmax $ fst $ foldl f ([p],[(p,a,sc)]) acts
 where f (ps,_:s) Close                  = (ps,s)
       f state Draw                      = state
       f (ps,(p,a,sc):s) (Jump d)        = (p:q:ps,(q,a,sc):s)
                                           where q = successor p (d*sc) a
       f (ps,(p,a,sc):s) (JumpA d)       = (p:q:ps,(q,a,sc):s)
                                           where q = successor p d a
       f (ps,(p,a,sc):s) (Move d)        = (p:q:ps,(q,a,sc):s)
                                           where q = successor p (d*sc) a
       f (ps,(p,a,sc):s) (MoveA d)       = (p:q:ps,(q,a,sc):s)
                                           where q = successor p d a
       f (ps,s@((p,a,sc):_)) (Scale sc') = (ps,(p,a,sc*sc'):s)
       f (ps,(p,a,sc):s) (Turn b)        = (ps,(p,a+b,sc):s)
       f (ps,s@(st:_)) (Widg b w)        = (g b ps st w,s)
       f (ps,s@(st:_)) _                 = (ps,st:s)
       g b ps (p,a,sc) w = if l == r then ps else l:r:ps
                        where (l,r) = ((x1,y1),(x2,y2))
                              (x1,y1,x2,y2) = minmax $ getFramePts True 
                                                      $ moveTurnScale b p a sc w

-- * __Picture__ operators

movePict :: Point -> Picture -> Picture
movePict = map . moveWidg

moveWidg :: Point -> WidgTrans
moveWidg p = updState f where f (_,a,c,i) = (p,a,c,i)

-- | transXY (x,y) w moves w x units to the right and y units to the bottom.
transXY :: (Double, Double) -> Widget_ -> Widget_
transXY (0,0) w = w
transXY (a,b) w = moveWidg (x+a,y+b) w where (x,y) = coords w

turnPict :: Double -> Picture -> Picture
turnPict = map . turnWidg

turnWidg :: Double -> WidgTrans
turnWidg a = updState f where f (p,b,c,i) = (p,a+b,c,i)

moveTurn :: Bool -> Point -> Double -> WidgTrans
moveTurn True p a = turnWidg a . moveWidg p 
moveTurn _ p a    = updState f where f (_,_,c,i) = (p,a,c,i)

-- | moveTurnScale is used by mkPict and 'widgFrame'.
moveTurnScale :: Bool -> Point -> Double -> Double -> Widget_ -> Widget_
moveTurnScale b p a sc = scaleWidg sc . moveTurn b p a
                              
updCol :: Color -> WidgTrans
updCol (RGB 0 0 0) = id
updCol c             = updState f where f (p,a,_,i) = (p,a,c,i)
                              
hueCol :: Int -> Picture -> Picture
hueCol m pict = map f $ indices_ pict
                 where n = length pict
                       f k = updState g $ pict!!k
                            where g (p,a,c,i) = (p,a,hue m c n k,i)

shiftCol :: Int -> WidgTrans
shiftCol n w | isRedDot w = w
             | n == 0     = w
             | n > 0      = updState (f n) w
             | otherwise  = updState (f $ 1530+n) w
                            where f n (p,a,c,i) = (p,a,iterate nextCol c!!n,i)

chgColor :: (Color -> Color) -> WidgTrans
chgColor f = updState g where g (p,a,c,i) = (p,a,f c,i)

shiftLight :: Int -> WidgTrans
shiftLight j = updState f where f (p,a,c,i) = (p,a,c,i+j)

lightWidg :: WidgTrans
lightWidg = updState f where f (p,a,c,i) = (p,a,light c,i)

delPict :: Picture -> Picture
delPict = map delWidg

delWidg :: WidgTrans
delWidg = updState f where f (p,a,_,_) = (p,a,RGB 1 2 3,0)

flipPict :: Bool -> Picture -> Picture
flipPict hor = map f
        where f (Arc (p,a,c,i) t r b)   = Arc (p,new a,c,i) t r $ -b
              f (Path st n ps)          = Path st n $ map h ps 
              f (Poly (p,a,c,i) n rs b) = Poly (p,new a,c,i) n rs $ -b
              f (Tria st r) | hor       = Tria st $ -r
              f (Tree st n c ct)        = Tree st n c $ mapT3 h ct
              f (Turtle st sc acts)     = Turtle st sc $ if hor then map g acts
                                                           else back:map g acts
              f (Bunch w is) = Bunch (f w) is       
              f (Fast w)     = Fast $ f w      
              f (Repeat w)   = Repeat $ f w
              f w             = w
              g (Turn a)   = Turn $ -a
              g (Widg b w) = Widg b $ f w
              g act        = act
              h (x,y) = if hor then (x,-y) else (-x,y)
              new a   = if hor then -a else a+180
            
widgArea :: Widget_ -> Double
widgArea w = area $ if isPict w then head outer else g $ head $ hulls False w
             where (_,_,_,outer,_) = strands [w]
                   g (Path0 _ _ _ ps) = ps    

outline :: Picture -> Picture
outline = map $ turtle0B . acts
          where acts w = map widg $ w:if isPict w then map (f c i) outer 
                                                  else map g $ hulls False w
                         where (_,_,_,outer,_) = strands [w]
                               (_,_,c,i) = getState w
                f c i = Path (p0,0,c,i-16) 2
                g (Path0 c i _ ps) = f c i ps
            
dots :: Int -> Picture -> Picture
dots n = map $ turtle0B . acts
 where acts w = widg w:if isPict w then concatMap (f c i) outer 
                                   else concatMap g $ hulls False w
                where (_,_,_,outer,_) = strands [w]
                      (_,_,c,i) = getState w
       f c i = h $ Oval (p0,0,c,i-16) 5 5
       g (Path0 c i _ ps) = f c i ps
       h w ps = mkActs (replicate lg w) $ map (\p -> (p,0)) qs
                where (qs,lg) = reduce ps
       reduce ps = if lg < n+1 then (ps,lg) else (map (ps!!) $ f [lg-1],n)
                  where lg = length ps; step = perimeter ps/(fromInt n-1)
                        f is@(i:_) = if null ks then is else f $ maximum ks:is
                                   where ks = filter b [0..i-1]
                                         b k = step <= distance (ps!!k) (ps!!i)
             
planarWidg :: Int -> WidgTrans
planarWidg maxmeet w = turtle0B $ head $ getMax acts $ pairs ws
         where acts = getActs w
               (ws,as) = split f acts where f (Widg _ _) = True; f _ = False
               f v w = sum (map area $ msum inner)
                      where (_,inner,_,_,_) =
                             strands [turtle0B $ filter (`elem` (v:w:as)) acts]
               pairs (v:ws) = [(v,w) | w <- ws, f v w > fromInt maxmeet] ++
                              pairs ws
               pairs _      = []        
               
-- ... = if sum (map area $ msum inner) > fromInt maxmeet then u else w
--       where u:v:_ = mkPict w; (_,inner,_,_,_) = strands [u,v]
                                                          
planarAll :: Int -> Graph -> Maybe Widget_ -> [Int] -> Double -> (Graph,[Int])
planarAll maxmeet (pict,arcs) (Just rect) rectIndices rscale = (graph',is)
                       where Rect (p@(x,y),_,_,_) b h = rect
                             k:ks = rectIndices
                             w = transXY p $ reduce $ mkTurt (x-b,y-h) rscale 
                                           $ map (pict!!) rectIndices
                             reduce = scaleWidg (1/rscale) . planarWidg maxmeet
                             graph = removeSub (updList pict k w,arcs) ks
                             (graph',n) = unTurtG graph rscale (== k)
                             m = length $ fst graph
                             is = k:[m..m+n-1]
                             --(x1,y1,x2,y2) = pictFrame $ map (pict'!!) is
                             --(b',h') = (abs (x2-x1)/2,abs (y2-y1)/2)
                             --r = Rect ((x1+b',y1+h'),0,black,0) b' h'
planarAll maxmeet (pict,_) _ _ scale = 
                         (fst $ unTurtG graph scale $ const True,[])
                        where graph = ([reduce $ mkTurt p0 scale pict],[[]])
                              reduce = scaleWidg (1/scale) . planarWidg maxmeet
                              
smooth :: Picture -> Picture                   -- uses Tcl's splining
smooth = map f
        where f (Path st m ps)   | m `elem` [0,2,4] = Path st (m+1) ps
              f (Poly st m rs b) | m `elem` [0,2,4] = Poly st (m+1) rs b
              f (Rect st@((x,y),_,c,_) b h) = Path st (filled c+1) $ last ps:ps
                                   where ps = [(x2,y1),(x2,y2),(x1,y2),(x1,y1)]
                                         x1 = x-b; y1 = y-h; x2 = x+b; y2 = y+h
              f (Tria st@((x,y),_,c,_) r)   = Path st (filled c+1) $ last ps:ps
                                   where ps = [(x+lg,z),(x-lg,z),(x,y-r)]
                                         lg = r*0.86602       -- r*3/(2*sqrt 3) 
                                                              -- sidelength/2
                                         z = y+lg*0.57735     -- y+lg*sqrt 3/3
              f (Turtle st sc acts) = Turtle st sc $ map g acts
              f (Bunch w is)        = Bunch (f w) is
              f (Fast w)            = Fast $ f w
              f (Repeat w)          = Repeat $ f w
              f w                   = w
              g (Open c m) | m `elem` [0,2,4] = Open c $ m+1
              g (Widg b w)                        = Widg b $ f w
              g act                               = act

splinePict :: Picture -> Picture                     -- uses Expander's splining
splinePict = map $ turtle0B . map f . hulls False
             where f (Path0 c i m ps) = widg $ Path (p0,0,c,i) m 
                                             $ if odd m then ps else spline ps

mkHue :: Num b => (b -> Color -> Color) -> Color -> [TurtleAct] -> [TurtleAct]
mkHue next c acts = fst $ foldl f ([],c) acts
             where n = foldl g 0 acts where g n (Widg _ _) = n+1
                                            g n (Open _ _) = n+1
                                            g n Close      = n-1
                                            g n _              = n
                   f (acts,c) act = case act of 
                             Widg b w -> (acts++[Widg b $ updCol c w],next n c)
                             _ -> (acts++[act],c)

-- | mkSnow b huemode d m n k w computes a Koch snowflake from widget w with 
-- turn 
-- mode m in {1,..,6}, depth n and the k copies of scale(i/3)(w) at level 
-- 1<=i<=n revolving around each copy of scale((i-1)/3)(w) at level i-1. 
-- The real number d should be taken from the closed interval [-1,1]. 
-- d affects the radia of the circles consisting of k copies of w.
mkSnow :: Bool -> Int -> Double -> Int -> Int -> Int -> Widget_ -> Widget_
mkSnow withCenter huemode d m n k w = 
      if n <= 0 then Skip else mkTurt p0 1 $ color $ if withCenter 
                                                           then w:g (n-1) r [p0]
                                                     else g (n-1) r [p0]
      where color = if huemode < 4 then id else hueCol $ huemode-3
            ps = getFramePts False w
            r = maximum $ map (distance $ gravity w) ps
            a = 360/fromInt k
            pict = if isTurtle w then mkPict w else [w]
            mkWidg [w]  = w
            mkWidg pict = shiftWidg (gravity w') w' where w' = mkTurt p0 1 pict
            g :: Int -> Double -> Path -> Picture
            g 0 _ _  = []
            g i r ps = zipWith3 h qs angs flips ++ g (i-1) r' qs
              where qs = concatMap circle ps 
                    r' = r/3
                    circle p@(x,y) = if odd m then s else p:s
                           where s = take k $ iterate (rotate p a) (x,y-r+d*r')
                    pict' = if huemode < 4 
                            then zipWith updCol (map (f . getCol) pict) pict
                            else pict
                    f col = hue huemode col n $ n-i
                    h p a b = moveWidg p $ turnWidg a $ scaleWidg (b/3^(n-i)) 
                                                             $ mkWidg pict'
            angs | m < 5  = zeros 
                 | m == 5 = iter++angs
                 | otherwise = 0:iter++concatMap f [1..n-2]
                            where f i = concatMap (g i) iter 
                                  g 1 a = a:iter
                                  g i a = g k a++f k where k = i-1
            iter = take k $ iterate (+a) 0
            zeros = 0:zeros
            flips = case m of 1 -> blink
                              2 -> 1:take k blink++flips
                              _ -> ones
            blink = 1: -1:blink
            ones  = 1:ones
                            
rainbow :: Int -> Double -> Double -> (Color -> Color) -> WidgTrans
rainbow n a d next w = turtle1 $ jumpTo p ++ f (shiftWidg p w) n
                       where p = gravity w
                             f _ 0 = []
                             f w i = widg (scaleWidg (fromInt i/fromInt n) w):
                                     Turn a:Jump d:f (chgColor next w) (i-1)

shine :: Int -> Double -> Double -> WidgTrans
shine i a d w = turtle1 $ jumpTo p ++ f (shiftWidg p w) n 
                 where p = gravity w
                       n = abs i
                       next = shiftLight $ 42 `div` i
                       f w 0 = []
                       f w i = widg (scaleWidg (fromInt i/fromInt n) w):Turn a:
                               Jump d:f (next w) (i-1)

track :: (Widget_ -> Point) -> String -> Int -> (Int -> Color -> Color) 
                                              -> WidgTrans
track center mode m next w = if null ps then Skip
                             else turtle1 $ map widg 
                                          $ pr1 $ fold2 g ([],p,getCol w) qs ks
             where ps@(p:qs) = getAllPoints w
                   ks = case mode of "asc" -> indices_ ps
                                     "sym" -> sym
                                     "ang" -> h angle
                                     _   -> h slope
                   n = maximum ks
                   r = center w
                   g (ws,p,c) q _ = (ws++[path0 c m [p,q,r,p]],q,next n c)
                   lg1 = length ps-1
                   lg2 = lg1`div`2
                   half = [0..lg2-1]
                   sym = half++if lg1`mod`2 == 0 then reverse half
                                                 else lg2:reverse half
                   h rel = map f rels
                          where rels = fst $ foldl g ([],p) qs
                                g (is,p) q = (is++[rel p q],q)
                                set = qsort (<=) $ mkSet rels
                                f rel = case search (== rel) set of Just i -> i
                                                                    _ -> 0

wave :: Int -> Int -> Double -> Double -> Color -> [TurtleAct]
wave mode n d a c = Open c mode:Jump (-fromInt n*x):down:Jump (-5):up:
                    border a++border (-a)++[Close]
                    where (x,_) = successor p0 d a
                          border a = foldl1 (<++>) (replicate n acts)++
                                     [down,Move 10,down]
                                     where acts = [Turn a,Move d,Turn $ -a-a,
                                                         Move d,Turn a]

-- * animations

onoff :: Widget_ -> TurtleActs
onoff w = [wfast w,wait,wfast $ delWidg w]

rotatePict :: Double -> [Widget_] -> [TurtleAct]
rotatePict a pict = take ((2*length pict+2)*round (360/abs a)) acts
                    where acts = wait:map wfast (delPict pict)++Turn a:
                                      map wfast pict++acts

fade :: Bool -> Widget_ -> [TurtleAct]
fade b = take 168 . if b then f 42 else g 0
         where f i w = if b && i == 0 then g 42 w
                       else wfast w:wait:f (i-1) (shiftLight 1 w)
               g i w = if not b && i == -42 then f 0 w
                       else wfast w:wait:g (i-1) (shiftLight (-1) w)

flash :: Widget_ -> [TurtleAct]
flash = take 100 . f where f w = wfast w:wait:f (chgColor (nextColor 1 50) w)

peaks :: Bool -> Int -> Color -> [Double] -> [TurtleAct]
peaks b mode c rs = if b then take 103 $ f 2 else take 102 $ g (w 36) 35
        where f i = onoff (w i)++f (i+1) 
              g v i = wait:wfast (delWidg v):wfast wi:g wi (i-1) where wi = w i
              w i = Poly (st0 c) mode (take k $ cycle rs) $ 360/fromInt k
                    where k = i*length rs
                                      
oscillate :: (Int -> TurtleActs) -> Int -> TurtleActs
oscillate acts n = take (6*n-2) $ f n
                   where f 0 = g 1
                         f i = onoff (turtle0B $ acts i)++f (i-1) 
                         g i = onoff (turtle0B $ acts i)++g (i+1) 

pulse :: [Widget_] -> TurtleActs
pulse pict = oscillate acts 20 
              where acts i = map (wfast . scaleWidg (fromInt i/20)) pict

oleaf :: Int -> Color -> TurtleActs
oleaf n c = oscillate acts $ min 33 n
            where acts i = leafC (fromInt n) (fromInt i*b) c c
                  b = if n < 33 then 1 else fromInt n/33

owave :: Int -> Int -> Double -> Int -> Color -> TurtleActs
owave mode n d m c = oscillate acts $ abs m
                      where acts i = wave mode n d (fromInt $ signum m*i) c

plait :: Int -> Int -> Double -> Int -> Color -> TurtleActs
plait mode n d m c = oscillate acts m
                      where acts i = wave mode n d (fromInt i) c ++
                                    wave mode n d (-fromInt i) (complColor c)

-- table pict d n displays pict as a matrix with n columns and a horizontal and
-- vertical distance of d units between the ANCHORS of adjacent widgets. 
-- table returns an action sequence.
table :: [Widget_] -> Double -> Int -> Widget_
table pict d n = turtle0B $ concatMap g $ f pict
                 where f [] = []; f s  = take n s:f (drop n s)
                       g pict = open:concatMap h pict++[Close,down,Jump d,up]
                                where h w = [widg w,Jump d]

-- | shelf graph cols (dh,dv) align scaled ... mode displays graph as a matrix 
-- with cols columns and a horizontal/vertical spacing of dh/dv units between 
-- the borders of adjacent widgets. shelf returns a picture (scaled = True) or 
-- an action sequence (scaled = False). If mode = "m2", the widget anchors are 
-- aligned vertically and the columns according to the value of align (L/M/R). 
-- Otherwise the widget anchors are aligned horizontally and the rows according 
-- to align.
shelf :: Graph -> Int -> Point -> Char -> Bool -> Bool -> String -> Graph
shelf graph@([],_) _ _ _ _ _ _ = graph
shelf graph@(pict,_) cols (dh,dv) align centered scaled mode = 
 case mode of "m1" -> sh graph True False
              "m2" -> sh graph False False
              "c"  -> sh graph True True 
              _    -> graph
 where lg = length pict
       is = [0..lg-1]
       rows = lg `div` cols
       upb
          | isCenter mode = maximum levels
          | lg `mod` cols == 0 = rows - 1
          | otherwise = rows
       rowIndices = [0..upb]
       levels = nodeLevels True graph
       levelRow i = [j | j <- is, levels!!j == i]
       sh (pict,arcs) b center =
        if center 
        then case searchGet isSkip ws of
                  Just (i,w) -> (w:map (transXY (0,y)) (context i ws),arcs)
                                where y = ycoord w-ycoord (ws!!head (arcs!!i))
                  _ -> (ws,arcs)
        else (if scaled then pict1 b 
              else [turtle0B $ if centered then actsToCenter acts else acts],
              arcs)
        where ws = sortR (pict1 True) $ concatMap levelRow rowIndices
              rowList pict = if isCenter mode then f 0 [] else g pict []
                        where f i picts = if null r then picts
                                          else f (i+1) $ picts++[r]
                                          where r = [pict!!k | k <- levelRow i]
                              g pict picts = if null pict then picts
                                                   else g (drop cols pict) $
                                                    picts++[take cols pict]
              row = mkArray (0,upb) $ (if scaled then map $ moveWidg p0 
                                                 else id) . (rowList pict!!) 
              pict1 b = concatMap (g b f) rowIndices 
                       where f x z y = moveWidg $ if b then (x+z,y) else (y,x+z)
              acts = msum $ concatMap (g b f) rowIndices
                     where f x z y w = [open,Jump x',down,Jump y',up,
                                              widg w,Close]
                                 where (x',y') = if b then (x+z,y) else (y,x+z)
              g b f i = zipWith h (hshift b!i) $ row!i
                where h x = f x z $ vshift b!!i
                      z = case align of 'L' -> xm-xi; 'R' -> xm'-xi'
                                        _ -> (xm'+xm-xi'-xi)/2
                      (xi,xi') = widgFrames b!i
                      (xm,xm') = widgFrames b!last (maxis rel rowIndices)
                      rel i j = xi'-xi < xj'-xj where (xi,xi') = widgFrames b!i
                                                      (xj,xj') = widgFrames b!j
              xframe = widgFrame *** xcoord
              yframe = widgFrame *** ycoord
              hshift = mkArray (0,upb) . f
                       where f True = shiftW maxminx dh . map xframe . (row!)
                             f _    = shiftW maxminy dv . map yframe . (row!)
              vshift True = shiftW maxminy dv $ map (yframe . h) rowIndices
              vshift _    = shiftW maxminx dh $ map (xframe . h) rowIndices
              h = turtle0B . map widg . (row!)
              widgFrames b = mkArray (0,upb) $ g b . f 
                where f i = widgFrame $ turtle0B $ 
                            widg (head pict):acts b++[widg $ last pict]
                       where pict = row!i
                             acts True = [Jump $ last $ hshift True!i]
                             acts _    = [down,Jump $ last $ hshift False!i,up]
                      g True (x,_,x',_) = (x,x')
                      g _ (_,y,_,y')    = (y,y')
              widg = Widg True

-- | getSupport graph s t returns the red dots on a path from s to t. 
-- getSupport is used by releaseButton.
getSupport :: Graph -> Int -> Int -> Maybe [Int]
getSupport graph s t = 
      do (_,_:path@(_:_:_)) <- searchGet f $ buildPaths graph; Just $ init path
      where f path = s `elem` path && t `elem` path && g s <= g t
                     where g s = getInd s path

-- | pictToWTree is used by 'newPaint' and 'concatGraphs'.
pictToWTree :: Picture -> TermW
pictToWTree pict = case map f pict of [t] -> t
                                      ts -> F Skip $ zipWith g [0..] ts
                where f (WTree t) = t
                      f w         = F w []
                      g i (F w ts) = F w (map (g i) ts)
                      g i (V (Text_ _ _ [x] _)) | take 4 x == "pos " 
                                   = V $ posWidg $ "pos "++unwords (map show p)
                                     where p = i:getPos x
                      g _ t        = t

-- | concatGraphs is used by 'addOrRemove' and 'arrangeOrCopy'.
concatGraphs :: Point -> Double -> String -> [Graph] -> Graph 
concatGraphs _ _ _ []                 = nil2
concatGraphs _ _ _ [graph]            = graph
concatGraphs spread grade mode graphs = (msum pictures,foldl g [] edges)
 where (pictures,edges) = unzip $ map (bunchesToArcs . f) graphs
       f graph@(pict,_) = if any isWTree pict then onlyNodes ws else graph
                    where ws = wTreeToBunches m spread grade $ pictToWTree pict
       g arcs = (arcs++) . map (map (+ length arcs))
       m = if isTree mode then mode else "t1"

{- |
bunchesToArcs (pict,arcs) removes the bunches of pict and adds their edges to
arcs. bunchesToArcs is used by arrangeGraph, concatGraphs, scaleAndDraw and 
showInSolver (see above).
-}
bunchesToArcs :: ([Widget_], Arcs) -> ([Widget_], [[Int]])
bunchesToArcs graph@(pict,_) = (pict2,foldl removeCycles arcs1 cycles)
  where addArcs (pict,arcs) (m,Bunch w is) = (updList pict m w,
                                               updList arcs m $ arcs!!m`join`is)
        addArcs graph (m,Fast w)   = addArcs graph (m,w)
        addArcs graph (m,Repeat w) = addArcs graph (m,w)
        addArcs graph _            = graph
        bunches = zip [0..] $ map getBunch pict
        getBunch (Fast w)   = w
        getBunch (Repeat w) = w
        getBunch w          = w
        cycles = [(s,t,v,w,ts) | b@(s,Bunch v ts) <- bunches,
                                 (t,Bunch w [n]) <- bunches`minus1`b,
                                 t `elem` ts, n == s, isRedDot w]
        cycles' = map f cycles where f (s,t,v,w,_) = (t,s,w,v,[s])
        graph1@(pict1,_) = foldl addSmoothArc graph $ cycles++cycles'
        (pict2,arcs1) = foldl addArcs graph1 $ zip [0..] pict1
        removeCycles arcs (s,t,_,_,_) = map f $ indices_ arcs
                                           where f n | n == s = arcs!!n`minus1`t
                                                  | n == t = arcs!!n`minus1`s
                                                  | otherwise = arcs!!n

{- |
addSmoothArc graph (s,t,..) adds a smooth line from s to t together with the 
control points of the line. addSmoothArc is used by releaseButton False False 
and bunchesToArcs (see above).
-}
addSmoothArc :: Graph -> (Int,Int,Widget_,Widget_,[Int]) -> Graph
addSmoothArc (pict,arcs) (s,t,v,w,ts)
                         | s == t = (f [(xp,y),mid,(x,yp)],
                                    setArcs 3 [s,lg,i,j] [targets,[i],[j],[t]])
                         | otherwise = (f [r], setArcs 1 [s,lg] [targets,[t]])
                         where f = (pict++) . map (Dot red)
                               p@(xp,yp) = coords v 
                               mid@(x,y) = apply2 (+30) p
                               q@(xq,yq) = coords w
                               seORnw = signum (xq-xp) == signum (yq-yp) 
                               r = rotate (div2 $ add2 p q)
                                          (if seORnw then 90 else 270) p
                               lg = length arcs
                               (i,j) = (lg+1,lg+2)
                               targets = lg:ts `minus1` t
                               setArcs n = fold2 updList $ arcs++replicate n []
                    
arcsToBunches :: Graph -> Picture
arcsToBunches (Bunch w is:pict,ks:arcs) 
                                = Bunch w (is`join`ks):arcsToBunches (pict,arcs)
arcsToBunches (w:pict,is:arcs) = Bunch w is:arcsToBunches (pict,arcs)
arcsToBunches _                = []

-- | buildAndDrawPaths graph transforms the arcs of graph into paths that do not
-- cross the borders of the widgets of pict. buildAndDrawPaths is used by 
-- scaleAndDraw.
buildAndDrawPaths :: Graph -> [Path]
buildAndDrawPaths graph@(pict,_) = map f $ buildPaths graph
                     where f (n:ns) = p':ps++[q']
                                   where v = pict!!n
                                         w = pict!!last ns
                                         p = coords v
                                         ps = map (coords . (pict!!)) $ init ns
                                         q = coords w
                                         p' = hullCross (head $ ps++[q],p) v
                                         q' = hullCross (last $ p:ps,q) w

{- |
exchgWidgets pict s t exchanges the positions of nodes s and t in the graph 
and in the plane. exchgWidgets is used by releaseButton and arrangeButton.
-}
exchgWidgets :: Picture -> Int -> Int -> Picture
exchgWidgets pict s t = updList (updList pict s $ moveWidg (coords v) w) t
                                                $ moveWidg (coords w) v
                        where (v,w) = (pict!!s,pict!!t)

{- |
exchgPositions graph s t exchanges the positions of nodes s and t of graph in
the plane. exchgPositions is used by releaseButton and permutePositions.
-}
exchgPositions :: Graph -> Int -> Int -> Graph
exchgPositions graph@(pict,arcs) s t = (exchgWidgets pict s t,
                                         foldl paths2arcs arcs0 paths7)
      where arcs0 = replicate (length arcs) []
            paths = buildPaths graph
            paths1 = [path | path@(m:_) <- paths, 
                     let n = last path in m == s && n == t || m == t && n == s]
            paths' = paths `minus` paths1
            paths2 = [t:path | m:path <- paths', m == s]
            paths3 = [s:path | m:path <- paths', m == t]
            paths4 = [init path++[t] | path@(_:_) <- paths', last path == s]
            paths5 = [init path++[s] | path@(_:_) <- paths', last path == t]
            paths6 = [path | path@(m:_) <- paths',
                     m /= s && m /= t && let n = last path in n /= s && n /= t]
            paths7 = map reverse paths1++paths2++paths3++paths4++paths5++paths6 
            paths2arcs arcs (m:path@(n:_)) = paths2arcs arcs' path
                                 where arcs' = updList arcs m (arcs!!m`join1`n)
            paths2arcs arcs _ = arcs

{- |
buildPaths graph regards the nodes of each maximal path p of graph consisting
of red dots as control points of smooth lines that connect a direct
predecessor of p with a direct successor of p. buildPaths is used by
graphToTree, subgraph, releaseButton, buildAndDrawPaths and exchgPositions
(see above).
-}
buildPaths :: Graph -> Arcs
buildPaths (pict,arcs) = connect $ concatMap f $ indices_ pict
  where f i = if isSkip (pict!!i) then [] else [[i,j] | j <- arcs!!i]
        connect (path:paths) = connect2 path paths
        connect _            = []
        connect2 path paths 
           | hpath == lpath     = path:connect paths
           | lastdot || headdot = case search2 f1 f2 paths of 
                                  Just (i,True) -> connectC (ipath++paths!!i) i
                                  Just (i,_) -> connectC (paths!!i++tpath) i
                                  _ -> connect paths
           | otherwise          = path:connect paths
                        where hpath:tpath = path
                              (ipath,lpath) = (init path,last path)
                              lastdot = isRedDot (pict!!lpath)
                              headdot = isRedDot (pict!!hpath)
                              f1 path = lastdot && lpath == head path
                              f2 path = last path == hpath && headdot
                              connectC path i = connect2 path $ context i paths


-- CROSSINGS and PICTURE EXTENSIONS

-- hullCross (p1,p2) w computes the crossing of line with w such that p2 agrees
-- with the coordinates of w. 
-- hullCross is used by buildAndDrawPaths, convexPath and drawTrees.

hullCross :: Line_ -> Widget_ -> Point
hullCross line@(p1@(x1,y1),p2@(x2,y2)) w = 
     case w of Arc{}         -> head hull
               Gif _ w       -> hullCross line w
               Oval (_,0,_,_) rx ry  -> if p1 == p2 then p2 
                                        else (x2+rx*cos rad,y2+ry*sin rad) 
                                        where rad = atan2' (y1-y2) (x1-x2)
               Path _ _ ps   -> head $ f $ mkLines ps
               Text_{}       -> mindist p1 hull
               Tree{}        -> mindist p1 hull
               _ | isWidg w  -> head hull
                 | isPict w  -> mindist p1 hull
               Bunch w _     -> hullCross line w
               Fast w        -> hullCross line w
               Repeat w      -> hullCross line w
               _             -> p2
     where hull = f $ msum $ getFrameLns w
           f ls = if null ps then [p2] else map fromJust ps
                where ps = filter isJust $ map (crossing (line,p2)) $ addSuc ls

-- | crossing line1 line2 returns the crossing point of line1 with line2.
-- crossing is used by crossings, hullCross and interior.
crossing :: (Line_,Point) -> (Line_,Point) -> Maybe Point
crossing ((p1@(x1, y1), p2@(x2, _)), p5)
  ((p3@(x3, y3), p4@(x4, _)), p6)
          | x1 == x2 = if x3 == x4 then onLine else enclosed q1
          | x3 == x4 = enclosed q2
          | a1 == a2 =
            do guard $ b1 == b2
               onLine
          | otherwise = enclosed q
      where a1 = slope p1 p2
            a2 = slope p3 p4
            b1 = y1-a1*x1     -- p1, p2 and q2 solve y = a1*x+b1
            b2 = y3-a2*x3     -- p3, p4 and q1 solve y = a2*x+b2
            a = a1-a2
            q = ((b2-b1)/a,(a1*b2-a2*b1)/a)  -- q solves both equations
            q1 = (x1,a2*x1+b2)
            q2 = (x3,a1*x3+b1)
            enclosed p = do guard $ inFrame p1 p p2 && inFrame p3 p p4; next p
            onLine
                  | inFrame p1 p3 p2 = next p3
                  | inFrame p1 p4 p2 = next p4
                  | inFrame p3 p1 p4 = next p1
                  | otherwise =
                    do guard $ inFrame p3 p2 p4
                       next p2
            next p = do guard $ (p /= p2 || inFrame p1 p p5) &&
                                 (p /= p4 || inFrame p3 p p6)
                        Just p

type Crossing = (Point,(Line_,Line_))

-- | crossings lines1 lines2 returns all triples (p,line1,line2) with line1 in
-- lines1, line2 in lines2 and crossing point p of line1 and line2.
-- crossings is used by strands.
crossings :: Lines -> Lines -> [Crossing]
crossings lines1 lines2 = [(fromJust p,(fst line1,fst line2)) | 
                            line1 <- addSuc lines1, line2 <- addSuc lines2,
                           let p = crossing line1 line2, isJust p]

addSuc :: Lines -> [(Line_,Point)]
addSuc [] = []
addSuc ls = zip ls (map snd $ tail ls) ++
             [(line2,if p == fst line1 then snd line1 else p)]
             where line1 = head ls; line2 = last ls; p = snd line2

-- | interior p lines returns True iff p is located within lines.
-- interior is used by inWidget and strands.
interior :: Point -> Lines -> Bool
interior p = odd . length . filter (isJust . crossing ((p,q),q)) . addSuc 
             where q = (2000,snd p)

-- | strands pict computes the subpaths of the hulls hs of pict that enclose the
-- intersection resp. union of the elements of hs and connects them.
-- strands is used by dots, extendPict, outline, planarWidg and widgArea. 
strands :: Picture -> ([(Widget_,Widget_,[Crossing])],[[Path]],[Color],
                                                       [Path],[Color])
strands pict = (hcs,inner,innerCols,outer,map col outer)
      where hs = concatMap (hulls False) pict
            is = indices_ hs
            (inner,innerCols) = unzip $ map threadsI hcs
            hcs = [(h1,h2,cs) | i <- is, j <- is, i < j, 
                                let h1 = hs!!i; h2 = hs!!j
                                    cs = crossings (getLines h1) $ getLines h2,
                                notnull cs]
            outer = connect $ concatMap threadsO hs
            add ps pss = if null ps then pss else ps:pss
            threadsI (h1,h2,cs) = (inner,getColor h1)
                      where inner = connect $ strands b ps1++strands c ps2
                            ps1 = extend h1 sucs1
                            ps2 = extend h2 sucs2
                            sucs1 p = [r | (r,((q,_),_)) <- cs, p == q]
                            sucs2 p = [r | (r,(_,(q,_))) <- cs, p == q]
                            b = interior (head ps1) $ getLines h2
                            c = interior (head ps2) $ getLines h1
                            strands b ps = add qs pss
                                where (qs,pss,_) = foldl next ([],[],b) ps
                                      next (ps, pss, b) p
                                          | p `elem` map fst cs =
                                            if b then ([], (p : ps) : pss, False)
                                            else ([p], pss, True)
                                          | b = (p : ps, pss, b)
                                          | otherwise = ([], pss, b)
            threadsO h = add qs pss
                  where sucs p = [r | (h1,h2,cs) <- hcs, 
                                         (r,((p1,_),(p2,_))) <- cs, 
                                      (h,p) `elem` [(h1,p1),(h2,p2)]]
                        (qs,pss,_) = foldl next ([],[],Nothing) $ extend h sucs
                        next (ps,pss,r) p 
                                | p `elem` concatMap (map fst . pr3) hcs
                                       = if isJust r && g (mid (fromJust r) p)
                                         then ([p],ps:pss,Just p)
                                              else (p:ps,pss,Just p)
                                | g p  = ([],add ps pss,Nothing)
                                | otherwise = (p:ps,pss,Nothing)
                        g p = any (interior p ||| any (onLine p)) 
                                  $ map getLines $ minus1 hs h
                        mid p = div2 . add2 p
            extend h sucs = concatMap f (init ps) ++ [last ps]
                      where ps = getPoints h
                            f p = sort rel $ p:sucs p
                                where rel r r' = distance p r < distance p r'
            connect (ps:pss) = case search2 ((==) (last ps) . head) 
                                                 ((==) (head ps) . last) pss of
                                    Just (i,True) -> g i $ init ps++pss!!i
                                    Just (i,_)    -> g i $ pss!!i++tail ps
                                    _ -> ps:connect pss          
                               where g i = connect . updList pss i
            connect _               = []                   
            col ps = case searchGet (shares ps . getPoints) hs of
                            Just (_,h) -> getColor h; _ -> black
            getColor (Path0 c _ _ _) = c
                      
-- | extendPict is used by 'widgets' and 'scaleAndDraw'.
extendPict :: Int -> Picture -> Picture
extendPict m pict = case m of 
                         6  -> pict++map center pict
                         7  -> pict++concatMap (map dot . pr3) hcs
                         8  -> pict++zipWithL darkLine innerCols inner
                         9  -> pict++map whiteFill (msum inner)
                         10 -> pict++zipWithL lightFill innerCols inner
                         11 -> pict++evens (zipWithL fill innerCols inner)
                         12 -> pict++zipWith darkLine outerCols outer
                         13 -> pict++fillHoles light
                         _ -> zipWith lightFill outerCols rest++fillHoles id
               where center w = Dot (if any (inWidget p) $ minus1 pict w
                                     then grey else black) p where p = coords w 
                     dot = Dot (RGB 0 0 1) . fst
                     (hcs,inner,innerCols,outer,outerCols) = strands pict
                     whiteFill        = path0 white 4
                     darkLine c       = path0 (dark c) 2
                     lightFill c      = path0 (light c) 4
                     fill (RGB 0 0 0) = whiteFill
                     fill c           = path0 c 4
                     fillHoles f = zipWith g [0..] holes
                                   where g i = path0 (f $ hue 1 yellow n i) 4
                                         n = length holes
                     (holes,rest) = split hole outer
                     hole ps = any f $ minus1 outer ps
                               where f qs = all g ps
                                            where g p = interior p $ mkLines qs

{- |
convexHull ps computes the convex hull of ps by splitting ps into halves and 
connecting the subhulls by clockwise searching for and adding an upper and a
lower tangent; see Preparata/Hong, CACM 20 (1977) 87-93. The auxiliary 
function f adds to the hull all points of ps that are located on horizontal
or vertical lines of the hull. (For some unknown reason, the actual algorithm
g does not recognize these points as part of the hull.)
-}
convexHull :: Path -> Path
convexHull ps = f $ g ps
 where f (q@(x1,y1):qs@((x2,y2):_))
         | x1 == x2 && y1 < y2 = g [p | p@(x,y) <- ps, x == x1, y1 < y, y < y2]
         | x1 == x2 && y1 > y2 = h [p | p@(x,y) <- ps, x == x1, y1 > y, y > y2]
         | y1 == y2 && x1 < x2 = g [p | p@(x,y) <- ps, y == y1, x1 < x, x < x2]
         | y1 == y2 && x1 > x2 = h [p | p@(x,y) <- ps, y == y1, x1 > x, x > x2]
         | otherwise            = q:f qs where g ps = q:sort (<) ps++f qs
                                               h ps = q:sort (>) ps++f qs
       f qs = qs
       g ps
          | lg < 3 = ps
          | p1 == p2 && q1 == q2 || a == b = left ++ right
          | otherwise = h p2 p1 left ++ h q1 q2 right
          where lg = length ps
                (left, right) = apply2 g $ splitAt (div lg 2) ps
                minL@((a, _) : _) = minima fst left
                maxL = maxima fst left
                minR = minima fst right
                maxR@((b, _) : _) = maxima fst right
                minY = head . minima snd
                maxY = head . maxima snd
                upperLeft = h (maxY minL) (maxY maxL) left
                upperRight = h (maxY minR) (maxY maxR) right
                lowerLeft = h (minY maxL) (minY minL) left
                lowerRight = h (minY maxR) (minY minR) right
                (p1, q1) = upperTangent upperLeft upperRight
                (p2, q2) = lowerTangent lowerLeft lowerRight
       h p q ps@(_:_:_) = take (getInd q qs+1) qs 
                          where qs = drop i ps++take i ps; i = getInd p ps
       h _ _ ps         = ps

upperTangent :: [(Double, Double)]
             -> [(Double, Double)] -> ((Double, Double), (Double, Double))
upperTangent ps@(p1:_) (q1:qs@(q2:_)) 
                              | slope p1 q1 < slope q1 q2  = upperTangent ps qs
upperTangent (p1:ps@(p2:_)) qs@(q1:_) 
                               | slope p1 q1 <= slope p1 p2 = upperTangent ps qs
upperTangent (p1:_) (q1:_)                                     = (p1,q1)

lowerTangent :: [(Double, Double)]
             -> [(Double, Double)] -> ((Double, Double), (Double, Double))
lowerTangent (p1:ps@(p2:_)) qs@(q1:_) 
                               | slope p1 q1 < slope p1 p2  = lowerTangent ps qs
lowerTangent ps@(p1:_) (q1:qs@(q2:_)) 
                               | slope p1 q1 <= slope q1 q2 = lowerTangent ps qs
lowerTangent (p1:_) (q1:_)                                     = (p1,q1)

-- | convexPath is used by 'scaleAndDraw'.
convexPath :: Path -> [Widget_] -> ([Widget_], Path)
convexPath ps pict = if straight ps then (h ps,ps) else (h $ last qs:qs,qs)
  where qs = convexHull $ sort (<) ps
        f p q = Path0 blue 0 0 [g q p,g p q]
        g p q = hullCross (p,q) $ pict!!fromJust (search ((== q) . coords) pict)
        h ps = zipWith f ps $ tail ps

-- * __Turtle actions__

colText :: Color -> Sizes -> String -> TurtleAct
colText c (n,width) str = widg $ Text_ (st0 c) n [str] [width str]

blackText :: Sizes -> String -> TurtleAct
blackText = colText black

rectC :: Color -> Double -> Double -> TurtleAct
rectC c b = widg . Rect (st0 c) b

halfmax :: (a -> Int) -> [a] -> Double
halfmax width = (/2) . fromInt . maximum . map width

-- * alignments

drawAlignment :: Sizes -> Align_ String -> [TurtleAct]
drawAlignment sizes@(n,width) t = 
                  case t of Compl x y t -> f x t y red
                            Equal_ [x] t -> f x t x green
                            Equal_ (x:s) t -> f x (Equal_ s t) x green
                            Ins [x] t -> g t x
                            Ins (x:s) t -> g (Ins s t) x
                            Del [x] t -> h x t
                            Del (x:s) t -> h x $ Del s t
                            End s@(_:_) -> drawAlignment sizes $ Del s $ End []
                            _ -> []
 where f x t y color = 
                JumpA bt:open:blackText sizes x:down:moveDown ht color++
                open:blackText sizes y:jump t bt++Close:Close:Close:jump t bt++
                drawAlignment sizes t where bt = halfmax width [x,y]
       g t x = 
           jumpDown ht++JumpA bt:blackText sizes x:jump t bt++Close:move t wa++
           drawAlignment sizes t where wa = fromInt $ width x; bt = wa/2
       h x t = 
           jumpDown ht++move t wa++Close:JumpA bt:blackText sizes x:jump t bt++
           drawAlignment sizes t where wa = fromInt $ width x; bt = wa/2
       ht = fromInt n/2

jump :: Eq a => Align_ a -> Double -> [TurtleAct]
jump t bt = if t == End [] then [] else [JumpA bt,Move 30]

move :: Eq a => Align_ a -> Double -> [TurtleAct]
move t bt = if t == End [] then [MoveA bt] else [MoveA bt,Move 30]

jumpDown :: Double -> [TurtleAct]
jumpDown ht = [open,down,JumpA ht,Jump 30,JumpA ht,up]

moveDown :: Double -> Color -> [TurtleAct]
moveDown ht color = [Open color 0,JumpA ht,Move 30,JumpA ht,up]

-- * dissections

drawDissection :: [(Int, Int, Int, Int)] -> [TurtleAct]
drawDissection = concatMap f
     where f (x,y,b,h) = [open,Jump x',down,Jump y',up,rectC black b' h',Close]
                         where x' = 10*fromInt x+b'; y' = 10*fromInt y+h'
                               b' = 5*fromInt b; h' = 5*fromInt h

star :: Int -> Color -> Double -> Double -> [TurtleAct]
star n c = f $ n+n 
           where a = 180/fromInt n
                 f 0 _ _  = []
                 f n r r' = open:Jump r:Open c 4:Move (-r):Turn (-a):
                            Move r':Close:Close:Turn a:f(n-1) r' r

taichi :: Sizes -> [TermS] -> Color -> [TurtleAct]
taichi sizes s c = [open,circ c 120,down,widg $ Arc (st0 d) Pie 120 180,
                    Jump 60,back,circ d 60,circ c 12,open,jump1,down,jump2,
                    colText c sizes yang,Close,Jump 120,back,circ c 60,
                    circ d 12,open,jump1,down,jump2,colText d sizes yin,Close]
                   where d = complColor c; jump1 = Jump 32; jump2 = Jump 52
                         circ c r = widg $ Oval (st0 c) r r
                         (yin,yang) = case s of t:u:_ -> (root t,root u)
                                                [t] -> (root t,"")
                                                _ -> ("","")

blossom :: (t -> t) -> Int -> t -> (t -> [TurtleAct]) -> [TurtleAct]
blossom next n c acts = open:f (n-1) c++[Close] 
                        where f 0 c = acts c
                              f i c = acts c++Turn a:f (i-1) (next c)
                              a = 360/fromInt n

blossomD :: (r -> r) -> Int -> r -> (r -> r -> [TurtleAct]) -> [TurtleAct]
blossomD next n c acts = open:f (n-1) c++[Close] 
                         where f 0 c = acts c $ next c
                               f i c = acts c c'++Turn a:f (i-1) (next c')
                                              where c' = next c
                               a = 360/fromInt n

blosParse :: t -> TermS -> TermS -> TermS -> [Char]
          -> Maybe (Int, Int, Int, Double, Double)
blosParse x n r a mode = do hue:mode <- Just mode
                            hue <- parse nat [hue]
                            m <- search (== mode) leafmodes
                            n <- parsePnat n; r <- parseReal r
                            a <- parseReal a
                            Just (hue,m,n,r,a)


pie :: ArcStyleType 
    -> (Int -> Color -> Color) -> Color -> [Double] -> [TurtleAct]
pie m next c rs = open:f (n-1) c++[Close] 
                  where f 0 c = [act 0 c]
                        f i c = act i c:Turn b:f (i-1) (next n c)
                        act i c = widg $ Arc (st0 c) m (rs!!i) $ b+0.2
                        b = 360/fromInt n
                        n = length rs

leafD :: Double -> Double -> Color -> Color -> [TurtleAct]
leafD r a c c' = Open c 4:Turn a:move:g 5
                 where g 0 = Close:Open c' 4:Turn (-a):move:h 5
                       g n = Turn (-b):move:g (n-1)
                       h 0 = [Close]
                       h n = Turn b:move:h (n-1)
                       move = Move r; b = 2*a/5

leafA :: Double -> Double -> Color -> Color -> [TurtleAct]
leafA r a c c' = [open,Jump y,down,Jump x,Turn $ b-180,w c,Turn $ -b,
                   Jump $ 2*x,Turn $ b+180,w c',Close] 
                  where (x,y) = successor p0 r b; b = a/2
                        w c = widg $ Arc (st0 c) Chord r a

leafC :: Double -> Double -> Color -> Color -> [TurtleAct]
leafC h b c c' = chord True h b c ++ chord False h b c'

leafS :: Double -> Double -> Color -> [TurtleAct]
leafS d a c = Open c 5:go++back:go++[Close]
              where go = [up,move,down,Move $ 2*d,down,move,up]
                    up = Turn (-a); down = Turn a; move = Move d

chord :: Bool -> Double -> Double -> Color -> [TurtleAct]
chord left h b c = open:acts++
                    [Jump $ -r,widg $ Arc (st0 c) Chord r $ 2*a,Close]
                   where r = h^2/(2*b)+b/2; a = angle p0 (r-b,h)
                         acts = if left then [up,Jump $ 2*h,Turn $ 270+a]
                                        else [Turn a]

rhombH :: Widget_
rhombH = path0 green 5 [p0,(3,-2),(16,0),(3,2),p0]

rhombV :: Color -> Widget_
rhombV c = path0 c 5 [p0,(-6,-9),(0,-48),(6,-9),p0]

-- growing trees

mkTrunk :: Color -> String -> Widget_
mkTrunk c x = path0 c 4 $ p0:ps++[(90,0),p0]
    where ps = case x of "TR" -> [(45,-x1)]                        -- triangle
                         "SQ" -> [(0,-90),(90,-90)]                -- square
                         "PE" -> [(-x2,-x3),(45,-138.49576),(117.81153,-x3)]
                                                                   -- pentagon
                         "PS" -> [(-14.079101,-x7),(44.62784,-127.016685),
                                  (103.33478,-x7)]                 -- pentagonS
                         "PY" -> [(0,-90),(36,-135),(90,-90)]      -- pytree
                         "CA" -> [(7.5,-60),(22.5,-90),(67.5,-90),(82.5,-60)]
                                                                   -- cactus
                         "HE" -> [(-45,-77.94228),(0,-x4),(90,-x4),(135,-x1)]
                                                                   -- hexagon
                         "LB" -> [(-x2,-x3),(62.18847,-x3)]        -- rhombLB
                         "RB" -> [(27.811527,-x3),(117.81152,-x3)] -- rhombRB
                         "LS" -> [(-72.81154,-x5),(17.188461,-x5)] -- rhombLS
                         "RS" -> [(72.81153,-x6),(162.81152,-x6)]  -- rhombRS
          x1 = 77.94229;  x2 = 27.811533; x3 = 85.595085; x4 = 155.88458
          x5 = 52.900665; x6 = 52.900673; x7 = 88.89195

grow :: WidgTrans -> Widget_ -> [TurtleActs] -> TurtleActs
grow f w branches = widg (f w):
                    msum (zipWith g branches $ mkLines $ getAllPoints w)
                   where g [] _               = []
                         g branch (p@(x,y),q) = open:Jump x:down:Jump y:Turn a:
                                                     Scale (d/90):branch++close2
                                                where a = angle p q-90
                                                      d = distance p q

growM :: Int -> Color -> Widget_ -> [Bool] -> TurtleActs
growM n c w bs = f n c where f 0 _ = []
                             f i c = grow id (updCol c w) $ map g bs
                                     where g True = f (i-1) $ nextColor 1 n c
                                           g _    = []

growA :: Color -> TurtleActs -> [TurtleActs] -> TurtleActs
growA c acts branches = Open c 4:acts++Close:f acts branches
           where f (turn:Move d:acts) (b:bs) = turn:acts'++Jump d:f acts bs
                                     where acts' = if null b then []
                                                   else Scale (d/90):b++[Close]
                 f _ _ = []

growAM :: Int -> Color -> TurtleActs -> [Bool] -> TurtleActs
growAM n c acts bs = f n c 
                     where f 0 _ = []
                           f i c = growA c acts $ map g bs
                                   where g True = f (i-1) $ nextColor 1 n c
                                         g _    = []
                                                     
mkBased :: Bool -> Color -> Widget_ -> Maybe Widget_
mkBased b c w = do guard $ length ps > 2 && p == last ps && d /= 0
                   Just $ path0 c 4 rs  
          where ps@(p:_) = getAllPoints w
                (rs,d) = basedPts
                basedPts = (map (apply2 (*(90/d)) . rotate p0 a . sub2 p) rs,d)
                           where rs@(p:qs) = if b then ps else reverse ps
                                 q = last $ init qs
                                 d = distance p q
                                 a = -angle p q

flower :: (Eq a, Num a) => Color -> a -> [Widget_] -> [TurtleAct]
flower c mode (w1:w2:w3:w4:w5:_) = widg stick:up:
           case mode of 0 -> jump 0.8 50 60 w1++jump 0.8 8 110 w2++
                             jump 0.8 80 120 w3++jump 0.6 12 70 w4++turn 0.8 w5
                        1 -> jump 0.8 72 60 w1++jump 0.8 12 110 w2++
                             jump 0.6 12 70 w3++jump 0.8 54 70 w4++turn 0.6 w5
                        _ -> jump 0.8 40 110 w1++jump 0.8 24 60 w2++
                             jump 0.6 43 110 w3++jump 0.6 43 70 w4++turn 0.6 w5
           where stick = Path (p0,0,c,-16) 4 [p0,(-4,-8),(0,-150),(4,-8),p0]
                 jump sc n a w = Jump n:open:Turn a:Scale sc:widg w:close2
                 turn sc w = open:Turn 100:Scale sc:widg w:close2
flower _ _ _ = []

-- fractals

data Direction = North | East | South | West

north,east,south,west :: TurtleActs
north = [up,Move 10,down]
east  = [Move 10]
south = [down,Move 10,up]
west  = [Move $ -10]

hilbert :: Int -> Direction -> TurtleActs
hilbert 0 _   = []
hilbert n dir = 
          case dir of East -> hSouth++east++hEast++south++hEast++west++hNorth
                      West -> hNorth++west++hWest++north++hWest++east++hSouth
                      North -> hWest++north++hNorth++west++hNorth++south++hEast
                      South -> hEast++south++hSouth++east++hSouth++north++hWest
          where hEast = h East; hWest = h West; hNorth = h North
                hSouth = h South; h = hilbert $ n-1

hilbshelf :: Int -> [a] -> [a]
hilbshelf n s = foldl f s $ indices_ s
              where f s' i = updList s' (y*2^n+x) $ s!!i 
                             where (x,y) = apply2 (round . (/10)) $ hilbPath!!i
                                   hilbPath = mkPath $ hilbert n East
                                   mkPath = fst . foldl g ([p0],0)
                    g (ps,a) act = case act of 
                                   Move d -> (ps++[successor (last ps) d a],a)
                                   Turn b -> (ps,a+b)

fern2 :: (Eq r, Integral a, Num r) => a -> Color -> r -> Double -> [TurtleAct]
fern2 n c del rat = open:up:f n 0++[Close]
                    where f 0 _ = []
                          f n 0 = act:Draw:open:Turn 30:g del++Close:
                                  open:Turn (-30):g del++Close:act<:>g 0
                                  where act = Move $ rat^(n-1)
                                        g = f (n-1)
                          f n k = f (n-1) $ k-1
                          open = Open c 0

fractal :: String -> Int -> Color -> [TurtleAct]
fractal "bush" n c = Open c 0:up:f n c++[Close]
                  where f 0 _ = [Move 1]
                        f i c = acts<++>acts<++>acts++Draw:open:acts1++Close:
                                open:Turn (-25):acts<++>acts1<++>acts2++[Close]
                                where acts = f (i-1) $ nextColor 1 n c
                                      acts1 = acts2<++>acts2<++>acts2
                                      acts2 = Turn 25:acts
                                      open = Open c 0

fractal "bush2" n c = Open c 0:up:f n c++[Close]
             where f 0 _ = [Move 3]
                   f i c = acts<++>acts++Draw:open:Turn 20:acts<++>acts++Close:
                           open:Turn (-20):acts++Turn 20:acts++[Close]
                           where acts = f (i-1) $ nextColor 1 n c
                                 open = Open c 1

fractal "cactus" n c = growM n c (mkTrunk c "CA") [False,True,True,True]

fractal "cant" n c = Open c 0:acts 0 0
  where acts x y = if x < n' || y < n' 
                   then if even x 
                          then if even y
                             then if x > 0 
                                  then if y' < n then move (-1) 1 else move 1 0
                                  else if y' < n then move 0 1 else move 1 0
                             else if x' < n then move 1 (-1) else move 0 1
                        else if even y
                             then if y > 0 
                                  then if x' < n then move 1 (-1) else move 0 1
                                  else if x' < n then move 1 0 else move 0 1
                             else if y' < n then move (-1) 1 else move 1 0
                   else []
                   where n' = n-1; x' = x+1; y' = y+1
                         move 0 b = down:Move (fromInt b):up:Draw:acts x (y+b)
                         move a 0 = Move (fromInt a):Draw:acts (x+a) y
                         move a b = Turn c:Move d:Turn (-c):Draw:acts xa yb
                                 where xa = x+a; yb = y+b
                                       p = fromInt2 (x,y); q = fromInt2 (xa,yb)
                                       c = angle p q; d = distance p q

fractal "dragon" n c = Open c 0:f n++[Close]
                    where f 0 = [Move 10]
                          f i = Turn 45:f (i-1)++Turn (-135):g (i-1)++[Turn 45]
                          g 0 = [Turn 45,Move 10]
                          g i = f (i-1)++Turn 45:g (i-1)++[Turn (-45)]

fractal "fern" n c = Open c 0:up:f n c 1++[Close]
                 where f 0 _ _ = [Move 10]
                       f i c a = g 0.35 (a*50) (-a)++g 0.35 (-a*50) a++
                                 g 0.85 (a*2.5) a
                        where g sc a b = Move 10:Draw:Open c 0:Scale sc:Turn a:
                                         f (i-1) (nextColor 1 n c) b++close2

fractal "gras" n c = Open c 0:up:f n c++[Close]
               where f 0 _ = [Move 6]
                     f i c = m:open++h (-25)++m:open++h 37.5++Open c 1:m:h 12.5
                          where m = Move $ 2^i
                                open = [Draw,Open c 0]
                                h a = Turn a:f (i-1) (nextColor 1 n c)++[Close]

fractal ('g':'r':'a':'s':[m]) n c = Scale 6:open++up:f n++close2
               where f 0 = case m of 'D' -> leafD 0.5 30 green green
                                     'A' -> leafA 3 50 green green        
                                     'C' -> down:leafC 1 0.2 green green++[up]
                                     _ -> [widg $ scaleWidg 0.2 rhombH]
                     f i = m:up:open++acts++Close:open++down:acts++Close:
                           down:m:open++down:m<:>acts++Close:up:acts
                           where acts = f $ i-1;    m = Move $ 2^i
                                 up = Turn $ -22.5; down = Turn 22.5        
                     open = [Draw,Open c 0]

fractal "hexa" n c = growM n c (mkTrunk c "HE") $ replicate 6 True
                                   
fractal "hilb" n c = f n c East
                     where f 0 _ _   = []
                           f i c dir = g sdir++draw dir++g dir++draw sdir++
                                       g dir++draw (flip dir)++g (flip sdir)
                                       where g = f (i-1) $ nextColor 1 n c
                                             sdir = swap dir
                                             draw dir = Open c 0:m dir++[Draw]
                           swap North = West
                           swap East  = South
                           swap South = East
                           swap _     = North
                           flip North = South
                           flip East  = West
                           flip South = North
                           flip _     = East 
                           m North = north
                           m East  = east
                           m South = south
                           m West  = west

fractal "koch" n c = Open c 0:g n++h n
                     where f 0 = [Move 1,Draw]
                           f i = acts++Turn 60:g (i-1)++Turn 60:acts 
                                 where acts = f $ i-1
                           g i = f i++h i 
                           h i = Turn (-120):f i

fractal "penta" n c = growM n c (mkTrunk c "PE") $ replicate 5 True

fractal "pentaS" n c = growM n c (mkTrunk c "PS") [False,True,True]

fractal "pytree" n c = growM n c (mkTrunk c "PY") [False,True,True]

fractal "pytreeA" n c = growAM n c acts [False,True,True]
                where acts = [up,m,Turn 38.659805,Move 57.628117,Turn 91.14577,
                              Move 70.292244,Turn 50.19443,m,down,m] 
                      m = Move 90

fractal "wide" n c = Open c 0:up:f n c++[Close]
             where f 0 _ = [Move 3]
                   f i c = open:Turn 20:acts++open:Turn 20:acts1++Turn (-40):
                           acts1++open:Turn (-40):acts<++>acts1++g (i-1) c'
                           where acts = h (i-1) c'; acts1 = f (i-1) c'++[Close]
                                 c' = next c; open = Open c 0
                   g 0 _ = [Move 3]
                   g i c = h (i-1) c'<++>f (i-1) c' where c' = next c
                   h 0 _ = [Move 3]
                   h i c = acts<++>acts where acts = h (i-1) $ next c
                   next = nextColor 1 n

-- * bars and piles

bar :: Sizes -> Int -> Int -> Int -> Color -> [TurtleAct]
bar sizes size i h c = [open,blackText sizes a,up,JumpA ht,open,Jump i',
                         rectC c i' 5,Close,Jump h',rectC black h' 5,Close]
                       where i' = fromInt i; h' = fromInt h
                             a = show i; ht = fromInt size/2+3

colbars :: Sizes -> Int -> Color -> [TurtleAct]
colbars sizes size (RGB r _ _) = f r red++Jump 20:f r green++Jump 40:f r blue
                                 where f c = bar sizes size (abs c`div`4) 64

pile :: (Eq a, Eq a1, Num a, Num a1) =>
        a -> a1 -> [TurtleAct]
pile h i = open:up:f h i++[Close]
           where f 0 _ = []
                 f h 0 = Jump 20:frame:f (h-1) 0
                 f h i = Jump 20:quad:frame:f (h-1) (i-1)
                 frame = rectC black 10 10
                 quad = rectC (light blue) 10 10
pileR :: Int -> [Int] -> TurtleActs
pileR h is = actsToCenter $ open:up:f h (reverse is)++[Close]
             where f 0 _      = []
                   f n (i:is) = Jump 20:quad i:frame:f (n-1) is
                   f n _      = Jump 20:frame:f (n-1) []
                   frame = rectC black 10 10
                   quad i = rectC (hue 1 green h i) 10 10

-- * matrices

rectMatrix :: Sizes -> (String -> String -> TurtleActs) -> [String] 
                     -> [String] -> (String -> Double) -> (String -> Double) 
                    -> TurtleActs
rectMatrix sizes@(n,width) entry dom1 dom2 btf htf =
           actsToCenter $ down:open:up:rectC black bt ht:JumpA bt:  
                          rectRow lineHead ht btf dom2++Close:JumpA ht:
                          concatMap h dom3
           where lineHead a = [colText blue sizes a]
                 bt = halfmax width dom3+3
                 ht = fromInt n/2+3
                 h i = JumpA ht:open:up:rectC black bt ht:lineHead i++
                       JumpA bt:rectRow (entry i) ht btf dom2++[Close,JumpA ht]
                       where ht = htf i
                 dom3 = [i | i <- dom1, any notnull $ map (entry i) dom2]

rectRow :: (t -> [TurtleAct])
           -> Double -> (t -> Double) -> [t] -> [TurtleAct]
rectRow entry ht btf = concatMap f
                     where f j = JumpA bt:rectC black bt ht:entry j++[JumpA bt]
                                 where bt = btf j

matrixBool :: Sizes -> [String] -> [String] -> [(String,String)] -> TurtleActs
matrixBool sizes@(n,width) dom1 dom2 ps =
                      rectMatrix sizes entry dom1 dom2 btf $ const ht
                      where entry i j = if (i,j) `elem` ps 
                                        then [widg $ Oval (st0 red) m m] else [] 
                            m = minimum (ht:map btf dom2)-1
                            btf j = halfmax width [j]+3
                            ht = fromInt n/2+3

matrixList :: Sizes -> [String] -> [String] -> Triples String TermS
                    -> TurtleActs
matrixList sizes@(n,width) dom1 dom2 ts = 
            rectMatrix sizes entry dom1 dom2 btf htf
            where entry i j = open:down:JumpA back:concatMap h (f i j)++[Close]
                              where back = -(lg i j-1)*ht
                  h a = [blackText sizes a,JumpA $ ht+ht]
                  f i = map delBrackets . relLToFun ts i
                  lg i = max 1 . fromInt . length . f i
                  btf j = halfmax width (j:concatMap (`f` j) dom1)+3
                  htf i = maximum (map (lg i) dom2)*ht
                  ht = fromInt n/2+3

matrixTerm :: Sizes -> [(String,String,TermS)] -> TurtleActs
matrixTerm sizes@(n,width) ts = rectMatrix sizes entry dom1 dom2 btf htf
                 where (dom1,dom2) = sortDoms2 ts
                       entry i j = [act str] where (act,str) = f i j
                       f i = colTerm . g i
                       g i j = case lookupL i j ts of Just t -> t; _ -> V ""
                       btf j = halfmax width (j:map (snd . flip f j) dom1)+3
                       htf _ = fromInt n/2+3
                       colTerm t = (colText col sizes,delBrackets t) 
                                   where col = case parse colPre $ root t of 
                                                    Just (c,_) -> c; _ -> black

matrixWidget :: Sizes -> Pos -> [(String,String,TermS)] -> TurtleActs
matrixWidget sizes spread ts = rectMatrix sizes entry dom1 dom2 
                                                     btf htf
              where (dom1,dom2) = sortDoms2 ts
                    entry i j = [widg $ f i j]
                    f i j = mkWidg $ case lookupL i j ts of Just t -> t
                                                            _ -> V ""
                    btf j = (x2-x1)/2+3 
                            where (x1,_,x2,_) = pictFrame $ map (`f` j) dom1
                    htf i = (y2-y1)/2+3 
                            where (_,y1,_,y2) = pictFrame $ map (f i) dom2
                    mkWidg t = case widgets sizes spread t of
                                     Just [w] -> w
                                     _ -> text0 sizes $ showTerm0 t

delBrackets = f . showTerm0 where f ('(':a@(_:_)) | last a == ')' = init a
                                  f a                              = a

-- * partitions

drawPartition :: (Eq a, Num a) =>
                 Sizes -> a -> Term b -> [TurtleAct]
drawPartition sizes mode = f $ case mode of 0 -> levelTerm
                                            1 -> preordTerm 
                                            2 -> heapTerm
                                            _ -> hillTerm
    where f order = split True 100 100 . fst . order blue lab 
            where lab c n = (c,n)
                  split b dx dy (F _ ts@(_:_)) = open:acts++[Close]
                                    where acts = if b then split1 (dx/lg) dy ts
                                                      else split2 dx (dy/lg) ts
                                          lg = fromInt (length ts)
                  split _ dx dy t = [open,Jump dx',down,Jump dy',up,
                                            rectC c dx' dy',
                                     --blackText sizes $ show n,
                                     Close]
                                     where dx' = dx/2; dy' = dy/2; F (c,n) _ = t
                  split1 dx dy [t]    = split False dx dy t
                  split1 dx dy (t:ts) = split False dx dy t++Jump dx:
                                        split1 dx dy ts
                  split2 dx dy [t]    = split True dx dy t
                  split2 dx dy (t:ts) = split True dx dy t++down:Jump dy:up:
                                        split2 dx dy ts

-- * __String parser__ into widgets

-- | graphString is used by 'loadGraph'.
graphString :: Parser ([Widget_], [[Int]])
graphString = do symbol "("; pict <- list widgString; symbol ","
                 arcs <- list (list int); symbol ")"; return (pict,arcs)

-- widgString is used by loadWidget (see above).
widgString :: Parser Widget_
widgString   = msum [do symbol "Arc"; ((x,y),a,c,i) <- state; t <- arcType
                        r <- enclosed double; b <- enclosed double
                        let [x',y',r',a',b'] = map fromDouble [x,y,r,a,b]
                        return $ Arc ((x',y'),a',c,i) t r' b',
                     do symbol "Bunch"; w <- enclosed widgString
                        is <- list int; return $ Bunch w is,
                     do symbol "Dot"; c <- token hexcolor; (x,y) <- pair
                        let [x',y'] = map fromDouble [x,y]
                        return $ Dot c (x',y'),
                     do symbol "Fast"; w <- enclosed widgString
                        return $ Fast w,
                     do symbol "Gif"; file <- token quoted
                        hull <- enclosed widgString; return $ Gif file hull,
                     do symbol "New"; return New,
                     do symbol "Oval"; ((x,y),a,c,i) <- state
                        rx <- enclosed double; ry <- enclosed double
                        let [x',y',a',rx',ry'] = map fromDouble [x,y,a,rx,ry]
                        return $ Oval ((x',y'),a',c,i) rx' ry',
                     do symbol "Path"; ((x,y),a,c,i) <- state
                        n <- enclosed nat; ps <- list pair
                        let [x',y',a'] = map fromDouble [x,y,a]
                        return $ Path ((x',y'),a',c,i) n $ map fromDouble2 ps,
                     do symbol "Poly"; ((x,y),a,c,i) <- state
                        n <- enclosed nat; rs <- list (enclosed double)
                        b <- enclosed double
                        let [x',y',a',b'] = map fromDouble [x,y,a,b]
                        return $ Poly ((x',y'),a',c,i) n 
                                       (map fromDouble rs) b',
                     do symbol "Rect"; ((x,y),a,c,i) <- state
                        b <- enclosed double; h <- enclosed double
                        let [x',y',a',b',h'] = map fromDouble [x,y,a,b,h]
                        return $ Rect ((x',y'),a',c,i) b' h',
                     do symbol "Repeat"; w <- enclosed widgString
                        return $ Repeat w,
                     do symbol "Skip"; return Skip,
                     do symbol "Text_"; ((x,y),a,c,i) <- state 
                        n <- enclosed nat; strs <- list (token quoted)
                        lgs <- list int
                        let [x',y',a'] = map fromDouble [x,y,a]
                        return $ Text_ ((x',y'),a',c,i) n strs lgs,
                     do symbol "Tree"; ((x,y),a,c,i) <- state
                        n <- enclosed nat; c' <- token hexcolor; ct <- ctree
                        let [x',y',a'] = map fromDouble [x,y,a]
                        return $ Tree ((x',y'),a',c,i) n c' ct,
                     do symbol "Tria"; ((x,y),a,c,i) <- state
                        r <- enclosed double
                        let [x',y',a',r'] = map fromDouble [x,y,a,r]
                        return $ Tria ((x',y'),a',c,i) r',
                     do symbol "Turtle"; ((x,y),a,c,i) <- state
                        sc <- enclosed double; acts <- list turtleAct
                        let [x',y',a',sc'] = map fromDouble [x,y,a,sc]
                        return $ Turtle ((x',y'),a',c,i) sc' acts]
             where arcType   = msum [do symbol "chord"; return Chord,
                                     do symbol "arc"; return Perimeter,
                                     do symbol "pieslice"; return Pie]
                   pair = do symbol "("; x <- token double; symbol ","
                             y <- token double; symbol ")"; return (x,y)
                   {- unused
                   quad = do symbol "("; x1 <- token double; symbol ","
                             y1 <- token double; symbol ","
                             x2 <- token double; symbol ","
                             y2 <- token double; symbol ")"
                             return (x1,y1,x2,y2)
                   -}
                   state = do symbol "("; (x,y) <- pair; symbol ","
                              a <- token double; symbol ","
                              c <- token hexcolor; symbol ","
                              i <- enclosed int; symbol ")"
                              return ((x,y),a,c,i)
                   node = do symbol "("; b <- token quoted; symbol ","
                             (x,y) <- pair; symbol ","; lg <- enclosed int
                             symbol ")"; return (b,(x,y),lg)
                   turtleAct =   msum [do symbol "Close"; return Close,
                                       do symbol "Draw"; return Draw,
                                       do symbol "Jump"; d <- enclosed double
                                          return $ Jump (fromDouble d),
                                       do symbol "JumpA"; d <- enclosed double
                                          return $ JumpA (fromDouble d),
                                       do symbol "Move"; d <- enclosed double
                                          return $ Move (fromDouble d),
                                       do symbol "MoveA"; d <- enclosed double
                                          return $ MoveA (fromDouble d),
                                       do symbol "Open"; c <- token hexcolor
                                          m <- token nat; return $ Open c m,
                                       do symbol "Turn"; a <- enclosed double
                                          return $ Turn (fromDouble a),
                                       do symbol "Scale"; a <- enclosed double
                                          return $ Scale (fromDouble a),
                                       do symbol "Widg"; b <- enclosed bool
                                          w <- enclosed widgString
                                          return $ Widg b w]
                   ctree =   msum [do symbol "V"; (b,(x,y),lg) <- node
                                      let [x',y'] = map fromDouble [x,y]
                                      return $ V (b,(x',y'),lg),
                                   do symbol "F"; (b,(x,y),lg) <- node
                                      cts <- list ctree
                                      let [x',y'] = map fromDouble [x,y]
                                      return $ F (b,(x',y'),lg) cts]


replaceCommandButton :: ButtonClass button => IORef (ConnectId button)
              -> button -> IO () -> IO ()
replaceCommandButton connectIdRef button act = do
    id <- readIORef connectIdRef
    signalDisconnect id
    id <- button `on` buttonActivated $ act
    writeIORef connectIdRef id

replaceCommandMenu :: MenuItemClass menuItem
                   => IORef (ConnectId menuItem)
                   -> menuItem -> IO () -> IO ()
replaceCommandMenu connectIdRef menuItem act = do
    id <- readIORef connectIdRef
    signalDisconnect id
    id <- menuItem `on` menuItemActivated $ act
    writeIORef connectIdRef id
