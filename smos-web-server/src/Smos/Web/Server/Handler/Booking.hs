{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Smos.Web.Server.Handler.Booking
  ( getBookingR,
    getBookUserR,
    postBookUserR,
  )
where

import Control.Monad.Except
import qualified Data.ByteString.Lazy as LB
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Zones
import Data.Time.Zones.All
import GHC.Generics (Generic)
import ICal
import qualified Network.HTTP.Types as Http
import Servant.Types.SourceT as Source
import Smos.Web.Server.Handler.Import
import qualified Yesod

getBookingR :: Handler Html
getBookingR = withLogin $ \t -> do
  now <- liftIO getCurrentTime
  status <- runClientOrErr $ clientGetUserSubscription t
  let showBookingPage = status /= NotSubscribed
  withNavBar $ do
    $(widgetFile "booking")

getClientTZLabel :: Handler TZLabel
getClientTZLabel = do
  mTimezoneName <- lookupGetParam "timezone"
  let label = fromMaybe Etc__UTC $ mTimezoneName >>= (fromTZName . TE.encodeUtf8)
  pure label

getBookUserR :: Username -> Handler Html
getBookUserR username = do
  BookingSlots {..} <- runClientOrErr $ clientGetBookingSlots username

  let timezones :: [(TZLabel, TZ)]
      timezones = map (\tzl -> (tzl, tzByLabel tzl)) [minBound .. maxBound]

  -- TODO: make the user timezone configurable
  let userTimeZoneLabel = Europe__Zurich
  let userTimeZone = tzByLabel userTimeZoneLabel

  clientTimeZoneLabel <- getClientTZLabel
  let clientTimeZone = tzByLabel clientTimeZoneLabel

  let toUserLocalTime :: LocalTime -> LocalTime
      toUserLocalTime = utcToLocalTimeTZ clientTimeZone . localTimeToUTCTZ userTimeZone

  let clientOptions :: Map Day (Set (LocalTime, TimeOfDay, NominalDiffTime))
      clientOptions =
        M.fromListWith S.union $
          map
            (\(lt, dur) -> let LocalTime d tod = toUserLocalTime lt in (d, S.singleton (lt, tod, dur)))
            (M.toList bookingSlots)

  let formatDuration :: NominalDiffTime -> String
      formatDuration = formatTime defaultTimeLocale "%m min"

  withNavBar $ do
    token <- genToken
    $(widgetFile "book-user/select-slot")

data BookForm = BookForm
  { bookFormUserTime :: !LocalTime,
    bookFormUserTimeZone :: !TZLabel,
    bookFormClientTime :: !LocalTime,
    bookFormClientTimeZone :: !TZLabel,
    bookFormDuration :: !NominalDiffTime
  }
  deriving (Show, Eq, Generic)

bookForm :: FormInput Handler BookForm
bookForm =
  BookForm
    <$> ( LocalTime
            <$> ireq dayField "user-day"
            <*> ireq timeField "user-time-of-day"
        )
    <*> ireq timeZoneLabelField "user-time-zone"
    <*> ( LocalTime
            <$> ireq dayField "client-day"
            <*> ireq timeField "client-time-of-day"
        )
    <*> ireq timeZoneLabelField "client-time-zone"
    <*> ( (* 60) . (fromIntegral :: Int -> NominalDiffTime)
            <$> ireq intField "duration"
        )

tzLabelToText :: TZLabel -> Text
tzLabelToText = TE.decodeLatin1 . toTZName

timeZoneLabelField :: Field Handler TZLabel
timeZoneLabelField =
  checkMMap
    ( pure
        . ( \t -> case fromTZName t of
              Nothing ->
                Left $
                  T.pack $
                    unwords
                      [ "Unknown timezone: ",
                        show t
                      ]
              Just tz -> Right tz
          )
        . TE.encodeUtf8
    )
    tzLabelToText
    textField

postBookUserR :: Username -> Handler Html
postBookUserR username = do
  bf@BookForm {..} <- runInputPost bookForm
  liftIO $ print bf
  now <- liftIO getCurrentTime
  let userTimeZone = tzByLabel bookFormUserTimeZone
  let startDateTime = localTimeToUTCTZ userTimeZone bookFormUserTime
  let ical = [makeICALCalendar now startDateTime bookFormDuration]
  let icalText = renderICalendar ical

  withNavBar $ do
    token <- genToken
    $(widgetFile "book-user/booked")

makeICALCalendar :: UTCTime -> UTCTime -> NominalDiffTime -> ICal.Calendar
makeICALCalendar now startDateTime duration =
  (makeCalendar (ICal.ProdId "-//CS SYD//Smos//EN"))
    { calendarMethod = Just (ICal.Method "REQUEST"),
      calendarEvents =
        [ makeICALEvent now startDateTime duration
        ]
    }

makeICALEvent :: UTCTime -> UTCTime -> NominalDiffTime -> ICal.Event
makeICALEvent now startDateTime duration =
  ( makeEvent
      -- TODO make a good UID
      (ICal.UID "uid here")
      (DateTimeStamp (DateTimeUTC now))
  )
    { eventDateTimeStart = Just $ DateTimeStartDateTime $ DateTimeUTC startDateTime,
      eventDateTimeEndDuration = Just (Right (nominalDiffTimeDuration duration)),
      eventClassification = ClassificationPrivate,
      eventCreated = Just (Created now),
      -- TODO: Nice event description
      -- TODO: jitsi link in description, url, and location
      eventDescription = Just (Description "Hi Despina"),
      eventLocation = Just (Location "Nice location"),
      -- TODO more specific jitsi link
      eventURL = Just (URL "https://meet.jit.si/"),
      eventStatus = Just StatusTentative,
      -- TODO: Nice event summary
      eventSummary = Just (Summary "Hi Despina"),
      eventTransparency = TransparencyOpaque,
      eventAttendees =
        S.fromList
          -- TODO fill in user and client info
          [ (mkAttendee "mailto:user@example.com")
              { attendeeParticipationRole = ParticipationRoleRequiredParticipant,
                attendeeParticipationStatus = ParticipationStatusTentative,
                attendeeRSVPExpectation = RSVPExpectationTrue,
                attendeeCommonName = Just "User common name"
              },
            (mkAttendee "mailto:client@example.com")
              { attendeeParticipationRole = ParticipationRoleRequiredParticipant,
                attendeeParticipationStatus = ParticipationStatusTentative,
                attendeeRSVPExpectation = RSVPExpectationTrue,
                attendeeCommonName = Just "Client common name"
              }
          ]
    }
