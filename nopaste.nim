import times, math, os
import norm/[model, sqlite]
import hashids
import sugar, options, strformat, strutils
import prologue
import prologue/middlewares
import karax / [kbase, vdom, karaxdsl]
import times

const HASH_ID_SALT = "Some salt or pepper?"
type
  NoPasteId = string
  NoPasteEntry = ref object of Model
    name: string
    content: string
    nopasteId: NoPasteId
    dateCreation: float
    howLongValid: int
    volatile: bool ## remove after first get
  NoPaste = ref object
    db: DbConn

func newNoPaste(dbfile = getAppDir() / "db.sqlite3"): NoPaste =
  result = NoPaste()
  result.db = open(dbfile, "", "", "")

proc init(noPaste: NoPaste) =
  noPaste.db.createTables(NoPasteEntry())

proc getAllNopasteEntry(noPaste: NoPaste): seq[NoPasteEntry] =
  result = @[NoPasteEntry()]
  noPaste.db.select(result, "NoPasteEntry.id order by dateCreation desc")

proc getNopasteEntryById(noPaste: NoPaste, noPasteId: NoPasteId): Option[NoPasteEntry] =
  var entrys = @[NoPasteEntry()]
  try:
    noPaste.db.select(entrys, "NoPasteEntry.noPasteId = ?", noPasteId)
  except:
    # echo getCurrentExceptionMsg()
    return
  if entrys.len == 0: return
  return some(entrys[0])

proc genNoPasteId(dateCreation: float): string =
  var hashids = createHashids(HASH_ID_SALT)
  let (intpart, floatpart) = splitDecimal(dateCreation)
  result = hashids.encode(@[intpart.int, (floatpart * 1000).int])

proc getExpiredEntries(noPaste: NoPaste): seq[NoPasteEntry] =
  let now = epochTime()
  for entry in noPaste.getAllNopasteEntry():
    if (entry.dateCreation + entry.howLongValid.float) < now:
      result.add entry

proc deleteExpiredEntries(noPaste: NoPaste) =
  for entry in noPaste.getExpiredEntries():
    noPaste.db.delete(dup(entry))

proc deleteAllEntries(noPaste: NoPaste) =
  for entry in noPaste.getAllNopasteEntry():
    noPaste.db.delete(dup(entry))

proc updateNopasteEntryById(noPaste: NoPaste, noPasteId: NoPasteId, name, content: string) =
  var entry = NoPasteEntry()
  noPaste.db.select(entry, "NoPasteEntry.noPasteId = ?", noPasteId)
  entry.name = name
  entry.content = content
  noPaste.db.update(entry)

proc delete(noPaste: NoPaste, noPasteId: NoPasteId) =
  var entry = NoPasteEntry()
  noPaste.db.select(entry, "NoPasteEntry.noPasteId = ?", noPasteId)
  noPaste.db.delete(entry)

proc newNoPasteEntry(name, content: string, howLongValid:int = 1, volatile = false): NoPasteEntry = # 60 * 60 * 24 * 28
  result = NoPasteEntry()
  result.name = name
  result.content = content
  result.dateCreation = epochTime()
  result.howLongValid = howLongValid
  result.volatile = volatile
  result.nopasteId = genNoPasteId(result.dateCreation)

##### Render functions

proc render(entry: NoPasteEntry): VNode =
  result = buildHtml(tdiv):
    h1:
      text entry.name
    tdiv:
      text entry.noPasteId & " " & $entry.dateCreation.fromUnixFloat()
    tdiv:
      a(href = "/raw/" & entry.noPasteId):
        text "[raw]"
      a(href = "/delete/" & entry.noPasteId, class="delete"):
        text "[delete]"
    hr()
    pre:
      text entry.content

proc render(noPasteEntries: seq[NoPasteEntry]): VNode =
  result = buildHtml(tdiv):
    for entry in noPasteEntries:
      tdiv(class="entry"):
        a(href = "/get/" & entry.noPasteId):
          text fmt"-> {entry.name} " & $entry.dateCreation.fromUnixFloat()
        a(href = "/raw/" & entry.noPasteId):
          text "[raw]"
        a(href = "/delete/" & entry.noPasteId, class="delete"):
          text "[delete]"

proc renderMenu(): VNode =
  result = buildHtml(tdiv(id="menu")):
    a(href = "/"): text "home"
    a(href = "/add"): text "add"
    a(href = "/deleteAll", class = "delete"): text "deleteAll"


proc master(content: VNode): VNode =
  result = buildHtml(html):
    head:
      link(rel="stylesheet", href="/static/style.css")
    body:
      renderMenu()
      content

# Async Function
proc home*(noPaste: NoPaste, ctx: Context) {.async.} =
  var outp = ""
  resp $master(noPaste.getAllNopasteEntry().render())

proc add*(noPaste: NoPaste, ctx: Context) {.async.} =
  if ctx.request.reqMethod == HttpPost:
    var howLongValid = 0
    var volatile = false
    try:
      howLongValid = parseInt(ctx.getPostParams("howLongValid"))
    except:
      discard
    if howLongValid == -1: volatile = true
    var entry = newNoPasteEntry(ctx.getPostParams("name"), ctx.getPostParams("content"), howLongValid = howLongValid, volatile = volatile)
    noPaste.db.insert(entry)
    # resp redirect("/get/" & entry.noPasteId)
    resp redirect("/")
  else:
    var outp = ""
    var vnode = buildHtml(tdiv):
      form(`method` = "post"):
        select(name = "howLongValid", id = "howLongValid"):
          option(value = $int.high): text "forever"
          option(value = $initDuration(weeks = 4).inSeconds): text "one month"
          option(value = $initDuration(weeks = 1).inSeconds): text "one week"
          option(value = $initDuration(days = 1).inSeconds): text "one day"
          option(value = $initDuration(hours = 1).inSeconds, selected = "selected"): text "one hour"
          option(value = $initDuration(minutes = 5).inSeconds): text "5 minutes"
          option(value = $(-1) ): text "volatile (only one get)"
        input(name = "name", id = "name", placeholder = "name"):
          discard
        textarea(name = "content", id = "content", placeholder = "content"):
          discard
        button(id="mysubmit"):
          text "submit"
    resp $master(vnode)

proc deleteIfVolatile(noPaste: NoPaste, entry: var NoPasteEntry) =
  if entry.volatile:
    noPaste.db.delete(entry)

proc raw*(noPaste: NoPaste, ctx: Context) {.async.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  var entryOpt = noPaste.getNopasteEntryById(noPasteId)
  if entryOpt.isSome():
    ctx.response.setHeader("content-type", "text/plain")
    resp entryOpt.get().content
    noPaste.deleteIfVolatile(entryOpt.get())
  else:
    resp("404 :( ", Http404)

proc get*(noPaste: NoPaste, ctx: Context) {.async.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  var entryOpt = noPaste.getNopasteEntryById(noPasteId)
  if entryOpt.isSome():
    resp $master(entryOpt.get().render())
    noPaste.deleteIfVolatile(entryOpt.get())
  else:
    resp("404 :(", Http404)

proc delete*(noPaste: NoPaste, ctx: Context) {.async.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  noPaste.delete(noPasteId)
  resp redirect("/")

proc deleteAll*(noPaste: NoPaste, ctx: Context) {.async.} =
  noPaste.deleteAllEntries
  resp redirect("/")


proc doCleanup(noPaste: NoPaste) {.async.} =
  while true:
    # echo "cleanup"
    noPaste.deleteExpiredEntries()
    await sleepAsync(10_000)

var noPaste = newNoPaste()
noPaste.init()
# block:
#   var ee = newNoPasteEntry("foooo", "baaaa", howLongValid = int.high)
#   noPaste.db.insert(ee)
# block:
#   var ee = newNoPasteEntry("foooo", "baaaa", howLongValid = int.high)
#   noPaste.db.insert(ee)
# block:
#   var ee = newNoPasteEntry("foooo", "baaaa", howLongValid = int.high)
#   noPaste.db.insert(ee)
# block:
#   var ee = newNoPasteEntry("foooo", "baaaa", howLongValid = int.high)
#   noPaste.db.insert(ee)

let settings = newSettings(appName = "NoPaste", debug = false)
# var app = newApp(settings = settings, middlewares = @[debugRequestMiddleware()])
var app = newApp(settings = settings, errorHandlerTable=newErrorHandlerTable())
app.addRoute("/", proc (ctx: Context): Future[void] {.gcsafe.} = home(noPaste, ctx), @[HttpGet, HttpPost])
app.addRoute("/add", proc (ctx: Context): Future[void] {.gcsafe.} = add(noPaste, ctx), @[HttpGet, HttpPost])
app.addRoute("/raw/{noPasteId}", proc (ctx: Context): Future[void] {.gcsafe.} = raw(noPaste, ctx), HttpGet)
app.addRoute("/get/{noPasteId}", proc (ctx: Context): Future[void] {.gcsafe.} = get(noPaste, ctx), HttpGet)
app.addRoute("/delete/{noPasteId}", proc (ctx: Context): Future[void] {.gcsafe.} = delete(noPaste, ctx), HttpGet)
app.addRoute("/deleteAll", proc (ctx: Context): Future[void] {.gcsafe.} = deleteAll(noPaste, ctx), HttpGet)

asyncCheck noPaste.doCleanup()
app.run()
#### WEBSERVER END
# when isMainModule and false:
#   var noPaste = newNoPaste()
#   noPaste.init()

#   var ee = newNoPasteEntry("foooo", "baaaa")
#   noPaste.db.insert(ee)

#   # for xx in noPaste.getAllNopasteEntry(): echo xx[]
#   echo "Expired:"
#   for xx in noPaste.getExpiredEntries(): echo xx[]
#   noPaste.deleteExpiredEntries()
#   noPaste.updateNopasteEntryById(ee.noPasteId, "RAX", "REX")