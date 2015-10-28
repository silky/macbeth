{-# LANGUAGE OverloadedStrings #-}

module Lentils.Wx.WxToolBox (
  createToolBox
) where

import Lentils.Api.Api
import Lentils.Api.CommandMsg
import Lentils.Api.Move
import Lentils.Api.Game
import Lentils.Api.Seek
import Lentils.Wx.WxAbout
import Lentils.Wx.WxMatch
import Lentils.Wx.WxSeek
import Lentils.Wx.WxUtils
import Lentils.Wx.WxObservedGame
import Lentils.Wx.WxChallenge

import Control.Concurrent
import Control.Concurrent.Chan
import qualified Control.Monad as M (when)
import Data.List (elemIndex)
import Graphics.UI.WX
import Graphics.UI.WXCore
import System.IO

ficsEventId = wxID_HIGHEST + 51

--TODO: remove absolute paths to resources
--TODO: create new frames with complete channel, WxNewFrame CommandMsg (Chan CommandMsg)
--TODO: make game list sortable, configurable
--TODO: application icon
createToolBox :: Handle -> String -> Bool -> Chan CommandMsg -> IO ()
createToolBox h name isGuest chan = do
    vCmd <- newEmptyMVar

    -- main frame
    f  <- frame [ text := "Lentils"]
    status <- statusField [ text := name ]

    -- right panel
    right <- panel f []
    nb <- notebook right []

    -- tab1 : Sought list
    slp <- panel nb []
    sl  <- listCtrl slp [columns := [ ("#", AlignLeft, -1)
                                    , ("handle", AlignLeft, -1)
                                    , ("rating", AlignLeft, -1)
                                    , ("Time (start inc.)", AlignRight, -1)
                                    , ("type", AlignRight, -1)]
                                    ]
    set sl [on listEvent := onSeekListEvent sl h]
    listCtrlSetColumnWidths sl 100

    -- toolbar
    tbar   <- toolBar f []
    toolItem tbar "Seek" False  "/Users/tilmann/Documents/leksah/XChess/gif/bullhorn.jpg" [ on command := wxSeek h isGuest ]
    toolItem tbar "Match" False  "/Users/tilmann/Documents/leksah/XChess/gif/dot-circle-o.jpg" [ on command := wxMatch h isGuest ]

    -- tab2 : console
    cp <- panel nb []
    ct <- textCtrlEx cp (wxTE_MULTILINE .+. wxTE_RICH) [font := fontFixed]
    ce <- entry cp []
    set ce [on enterKey := emitCommand ce h]


    -- tab3 : Games list
    glp <- panel nb []
    gl  <- listCtrl glp [columns := [("#", AlignLeft, -1)
                                    , ("player 1", AlignLeft, -1)
                                    , ("rating", AlignLeft, -1)
                                    , ("player 2", AlignLeft, -1)
                                    , ("rating", AlignLeft, -1)
                                    ]
                        ]
    listCtrlSetColumnWidths gl 100

    -- Games list : context menu
    glCtxMenu <- menuPane []
    menuItem glCtxMenu [ text := "Refresh", on command := hPutStrLn h "4 games" ]


    -- about menu
    m_help    <- menuHelp      []
    m_about  <- menuAbout m_help [help := "About XChess", on command := wxAbout ]

    set f [ layout := container right
                         ( column 0
                         [ tabs nb
                            [ tab "Sought" $ container slp $ fill $ widget sl
                            , tab "Games" $ container glp $ fill $ widget gl
                            , tab "Console" $ container cp
                                            ( column 5  [ floatLeft $ expand $ hstretch $ widget ct
                                                        , expand $ hstretch $ widget ce])
                            ]
                         ])
          , menuBar := [m_help]
          , statusBar := [status]
          ]

    threadId <- forkIO $ eventLoop ficsEventId chan vCmd f

    windowOnDestroy f $ killThread threadId

    evtHandlerOnMenuCommand f ficsEventId $ takeMVar vCmd >>= \cmd -> case cmd of

        Games games -> do
          set status [text := name]
          set gl [items := [[show $ Lentils.Api.Game.id g, Lentils.Api.Game.nameW g, show $ ratingW g, Lentils.Api.Game.nameB g, show $ ratingB g]
                            | g <- games, not $ isPrivate $ settings g]]
          set gl [on listEvent := onGamesListEvent games h]
          --TODO: aufhübschen
          listItemRightClickEvent gl (\evt -> do
            pt <- listEventGetPoint evt
            menuPopup glCtxMenu pt gl)

        NoSuchGame -> set status [text := name ++ ": No such game. Updating games..."] >>
                      hPutStrLn h "4 games"

        NewSeek seek -> M.when (Lentils.Api.Seek.gameType seek `elem` [Untimed, Standard, Blitz, Lightning]) $
                               itemAppend sl $ toList seek

        ClearSeek -> itemsDelete sl

        RemoveSeeks gameIds -> do
          seeks <- get sl items
          sequence_ $ fmap (deleteSeek sl . findSeekIdx seeks) gameIds

        SettingsDone -> hPutStrLn h "4 iset seekinfo 1" >> hPutStrLn h "4 games"

        Observe move -> dupChan chan >>= createObservedGame h move White

        MatchAccepted move -> dupChan chan >>= createObservedGame h move (colorOfPlayer move)

        GameMove move -> when (isPlayersNewGame move) $ dupChan chan >>= createObservedGame h move (colorOfPlayer move)

        MatchRequested c -> dupChan chan >>= wxChallenge h c

        TextMessage text -> appendText ct $ text ++ "\n"

        _ -> return ()


findSeekIdx :: [[String]] -> Int -> Maybe Int
findSeekIdx seeks gameId = elemIndex gameId $ fmap (read . (!! 0)) seeks

deleteSeek :: ListCtrl () -> Maybe Int -> IO ()
deleteSeek sl (Just id) = itemDelete sl id
deleteSeek _ _ = return ()

toList :: Seek -> [String]
toList (Seek id name rating time inc isRated gameType color ratingRange) =
  [show id, name, show rating, show time ++ " " ++ show inc, show gameType ++ " " ++ showIsRated isRated]
  where showIsRated True = "rated"
        showIsRated False = "unrated"

onGamesListEvent :: [Game] -> Handle -> EventList -> IO ()
onGamesListEvent games h eventList = case eventList of
  ListItemActivated idx -> hPutStrLn h $ "4 observe " ++ show (Lentils.Api.Game.id $ games !! idx)
  _ -> return ()


onSeekListEvent :: ListCtrl() -> Handle -> EventList -> IO ()
onSeekListEvent sl h eventList = case eventList of
  ListItemActivated idx -> do
    seeks <- get sl items
    hPutStrLn h $ "4 play " ++ show (read $ head (seeks !! idx) :: Int)
  _ -> return ()


emitCommand :: TextCtrl () -> Handle -> IO ()
emitCommand textCtrl h = get textCtrl text >>= hPutStrLn h >> set textCtrl [text := ""]


listItemRightClickEvent :: ListCtrl a -> (Graphics.UI.WXCore.ListEvent () -> IO ()) -> IO ()
listItemRightClickEvent listCtrl eventHandler
  = windowOnEvent listCtrl [wxEVT_COMMAND_LIST_ITEM_RIGHT_CLICK] eventHandler listHandler
    where
      listHandler :: Graphics.UI.WXCore.Event () -> IO ()
      listHandler evt = eventHandler $ objectCast evt
