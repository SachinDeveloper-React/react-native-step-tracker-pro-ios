# How iOS records steps, and what this package does about it

What the platform actually does, from Apple's documentation and from what
others measured, and the decision each finding led to. Read this before
changing how steps are counted, judged or resolved.

## Findings

### 1. The iPhone keeps steps in records of 6 to 10 minutes

An analysis of exported Health data from one iPhone over several years
found that since iOS 10 the iPhone's step records are "at least 6 minutes
and ideally 10 minutes" long, with 10 as the maximum (before: about 5)
([David Molnar, 2017](https://dm516.user.srcf.net/?p=403)). Developers
report per-minute step data that looked averaged or compressed after iOS 11
([Apple Developer Forums 98966](https://developer.apple.com/forums/thread/98966)),
and forum answers from Apple describe high-frequency step samples being
condensed into series that carry a count above one.
Querying the pedometer over a few seconds often returns 0
([OwnTracks #889](https://github.com/owntracks/ios/issues/889)).

So minute-by-minute history is each record's average, not a measurement of
that minute. The minute-to-minute drift that tells a person from a machine
is averaged away, and so are rests shorter than a record.

**Decision.**
- **Two minute-shape rules are evidence only:** on iOS `steady_cadence` and
  `continuous` become *weak* flags, with `evidence.minuteData: 'averaged'`.
  Judged as exact minutes, a steady treadmill walk reads as a swing gadget,
  and a hike whose short rests were averaged away runs past the continuous
  limit. Both would take real steps out under `mode: 'exclude'`.
- **The other strong rules stay strong:** `cadence` (averaging only lowers
  peaks, so it adds no false positives), `daily_volume` and `charging`.
- **Impossible minutes are parked:** a minute over 500 steps is a lump the
  pedometer could not place. It is kept untimed, as Android does.
- **Minutes still sum exactly:** they always add up to
  `deviceSteps − gatedSteps`. A server computing active minutes should know
  they are averages over up to ten minutes.

### 2. The pedometer and motion history keep 7 days

"Only the past seven days worth of data is stored and available"
([CMPedometer.queryPedometerData](https://developer.apple.com/documentation/coremotion/cmpedometer/querypedometerdata(from:to:withhandler:))),
and the same for activities, which "a delay of up to several minutes" also
affects ([CMMotionActivityManager.queryActivityStarting](https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager/queryactivitystarting(from:to:to:withhandler:))).
A query's handler runs "on the same serial dispatch queue", so many queries
run one after another.

**Decision.**
- **What is kept:** each day is stored when computed. A day that leaves the
  week unsettled takes this iPhone's own Apple Health samples if they hold
  more of it.
- **Settling:** a day becomes final two hours after midnight, not ten
  minutes, so the record ending it has landed.
- **Without Apple Health access:** if the app is not opened for more than
  seven days, the oldest days cannot be recovered. With access, they can.

### 3. Apple Health de-duplicates iPhone and Watch by time

A statistics query with `.cumulativeSum` merges overlapping iPhone and Apple
Watch samples the way the Health app's total does; a sample query returns
both, undeduplicated ([Apple Developer Forums 784375](https://developer.apple.com/forums/thread/784375),
[109473](https://developer.apple.com/forums/thread/109473);
[Sahha](https://sahha.ai/blog/deduplicating-health-data-across-wearables/)).
The priority between them is not documented.

**Decision.** Android's resolver picks one origin per day, so a morning
walked with only the watch and an evening with only the phone loses one of
them - the user sees less than the Health app. Under `auto`, with nothing
pinned, iOS also merges this phone with each trusted wearable **hour by
hour**: the larger of the two in each hour, never their sum. It takes the
merge when it is larger. Each source's own figures are untouched in
`sources` for a server.

### 4. Background delivery is hourly, and easy to lose

For steps "on iOS ... an hourly maximum frequency". "As soon as your app
launches, HealthKit calls the update handler for any observer queries";
set them up in `didFinishLaunching`. "If your app fails to respond three
times, HealthKit ... stops sending background updates." It needs the
background-delivery entitlement, and does not work on the Simulator
([enableBackgroundDelivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)),
[Executing observer queries](https://developer.apple.com/documentation/healthkit/executing-observer-queries)).

**Decision.**
- **Registered at launch:** observers are registered synchronously on the
  main thread as launch finishes, from settings the previous run kept.
  Before, they were registered a moment later on the engine's queue, and an
  early delivery could find none. The launch and the engine register
  through one lock, and the engine's types replace the launch's whichever
  thread gets there first.
- **A wake is cheap:** the pedometer's settled hours are kept on disk, so a
  wake in a new process asks only for the last two or three hours instead of
  sixty minute queries for every hour with steps since midnight.
- **Answered within ten seconds:** the completion handler is called on its
  own timer. Before, the fallback waited behind the work it was meant to
  bound.

### 5. Health data is locked with the phone, and read grants are hidden

The store is encrypted when the device locks, so background reads can fail
with `errorDatabaseInaccessible`
([Protecting user privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)).
"Your app doesn't know whether someone granted or denied permission to read
data ... From the app's point of view, no data of that type exists." From
iOS 27 people can allow only "a limited window of recent data", the one
state an app can identify, through `getEarliestAuthorizedSampleDate`
([Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data);
iOS 27 SDK `HKHealthStore.h`).

**Decision.**
- **Locked phone:** reads failed while locked are retried on unlock, and a
  locked phone's evidence says `'failed'`.
- **Zero never settles a day:** a zero from Apple Health is never taken as a
  day's count, because a refused read looks the same.
- **Limited window:** it is reported as `historyReadGranted: false`, and
  nothing before it is read.

### 6. Phones count steps in vehicles

A bumpy drive adds hundreds of steps on an iPhone, as on every pedometer
([TidBITS](https://tidbits.com/2020/02/24/pedometer-apps-turn-your-iphone-into-a-step-counter/),
[Pacer](https://support.mypacer.com/hc/en-us/articles/41558300225549),
[Apple Community](https://discussions.apple.com/thread/255707443)).

**Decision.** The motion gate (`motionGate.enabled`) holds steps in minutes
CMMotionActivity reports as a vehicle or bicycle. It is off by default as on
Android; an app that rewards steps should turn it on.

### 7. How reward apps handle it

Sweatcoin converts only steps its own validation accepts - it checks the
phone's motion against other signals and rejects shaking and transport - so
its number is lower than the Health app's; steps are counted only when the
phone is carried; with Low Power Mode on it asks users to open the app every
12 hours and never to force-quit it
([Tom's Guide](https://www.tomsguide.com/us/sweatcoin-faq,review-5465.html),
[Sweatcoin help: improving step conversion on iOS](https://help.sweatco.in/hc/en-us/articles/360012681872-How-can-I-improve-my-step-conversion-iOS),
[Lilach Bullock](https://www.lilachbullock.com/how-does-sweatcoin-work/)).
Manual entries carry `HKMetadataKeyWasUserEntered` (YES, NO or absent) and no
device ([Stack Overflow](https://stackoverflow.com/questions/31184628)).

**What this package gives such an app.**
- **The phone's own count, apart:** `deviceSteps` from the coprocessor,
  never another app's.
- **Manual entries separated:** `manualSteps`, and
  `healthConnectIgnoreManualEntries` keeps them out.
- **Vehicle steps held**, with the gate on.
- **Integrity flags and a daily cap.**
- **A signed snapshot with App Attest** - the verdict is the server's, as
  Sweatcoin's is.

## Not done, and why

- **`BGAppRefreshTask`.** It would need the app's `Info.plist` to list a task
  identifier, it must be registered before launch ends (a second
  registration kills the app), and iOS rarely runs it for an app that is not
  being opened - the one case it would be for. Apple Health's delivery
  already wakes an app that has access.
- **Per-step timing from history.** iOS does not keep it. Live pedometer
  updates while the app is open are the only finer source.
