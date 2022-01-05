import times, math, os
import norm/[model, sqlite, pragmas, types]
import hashids
import sugar, options, strformat, strutils
import prologue
import prologue/middlewares
import prologue/middlewares/signedcookiesession
import prologue/middlewares/staticfile
import karax / [kbase, vdom, karaxdsl]
import times
import parsecfg

const
  ENABLE_DEFLATE = true # enables experimental compression of responses (just 4 fun)

var config = loadConfig(getAppDir() / "config.ini")

let
  USERNAME = config.getSectionValue("", "username")
  PASSWORD = config.getSectionValue("", "password")
  HASH_ID_SALT = config.getSectionValue("", "salt")
  uploadDir = getAppDir() / config.getSectionValue("", "uploadDir")
  secretKey = config.getSectionValue("", "secretKey")

type
  NoPasteId = string
  NoPasteEntry = ref object of Model
    name: string
    content: string
    nopasteId: NoPasteId
    dateCreation: float
    howLongValid: int
    volatile: bool ## remove after first get
    uploadFile: string
  ShortlinkId = string
  ShortlinkEntry = ref object of Model
    shortlinkId {.unique.}: ShortlinkId
    target: string
  NoPaste = ref object
    db: DbConn
    config: Config

proc loggedIn(ctx: Context): bool {.inline.} =
  ctx.session.getOrDefault("login") == $true

proc setFlash(ctx: Context, msg: string) {.inline.} =
  ctx.session["flash"] = msg

proc popFlash(ctx: Context): string  {.inline.} =
  result = ctx.session.getOrDefault("flash")
  ctx.session.del("flash")

proc hasFlash(ctx: Context): bool {.inline.} =
  ctx.session.getOrDefault("flash") != ""

proc newNoPaste(dbfile = getAppDir() / "db.sqlite3"): NoPaste =
  result = NoPaste()
  result.db = open(dbfile, "", "", "")

proc init(noPaste: NoPaste) =
  noPaste.db.createTables(NoPasteEntry())
  noPaste.db.createTables(ShortlinkEntry())
  if not dirExists(uploadDir): createDir(uploadDir)

proc getAllShortlinksEntry(noPaste: NoPaste): seq[ShortlinkEntry] =
  result = @[ShortlinkEntry()]
  noPaste.db.select(result, "ShortlinkEntry.id")

proc getAllNopasteEntry(noPaste: NoPaste): seq[NoPasteEntry] =
  result = @[NoPasteEntry()]
  noPaste.db.select(result, "NoPasteEntry.id order by dateCreation desc")

proc getNopasteEntryById(noPaste: NoPaste, noPasteId: NoPasteId): Option[NoPasteEntry] =
  var entrys = @[NoPasteEntry()]
  try:
    noPaste.db.select(entrys, "NoPasteEntry.noPasteId = ?", noPasteId)
  except:
    return
  if entrys.len == 0: return
  return some(entrys[0])

proc getShortlinkEntryById(noPaste: NoPaste, shortlinkId: ShortlinkId): Option[ShortlinkEntry] =
  var entrys = @[ShortlinkEntry()]
  try:
    noPaste.db.select(entrys, "ShortlinkEntry.shortlinkId = ?", shortlinkId)
  except:
    return
  if entrys.len == 0: return
  return some(entrys[0])

proc deleteUploadFile(noPaste: NoPaste, noPasteId: NoPasteId) =
  removeDir(uploadDir / nopasteId)

proc genNoPasteId(dateCreation: float): string =
  var hashids = createHashids(HASH_ID_SALT)
  let (intpart, floatpart) = splitDecimal(dateCreation)
  result = hashids.encode(@[intpart.int, (floatpart * 1000).int])

proc getExpiredEntries(noPaste: NoPaste): seq[NoPasteEntry] {.gcsafe.} =
  let now = epochTime()
  for entry in noPaste.getAllNopasteEntry():
    if (entry.dateCreation + entry.howLongValid.float) < now:
      result.add entry

proc deleteExpiredEntries(noPaste: NoPaste) {.gcsafe.} =
  for entry in noPaste.getExpiredEntries():
    noPaste.deleteUploadFile(entry.noPasteId)
    noPaste.db.delete(dup(entry))

proc deleteAllEntries(noPaste: NoPaste) {.gcsafe.} =
  for entry in noPaste.getAllNopasteEntry():
    noPaste.deleteUploadFile(entry.noPasteId)
    noPaste.db.delete(dup(entry))

proc updateNopasteEntryById(noPaste: NoPaste, noPasteId: NoPasteId, name, content: string) {.gcsafe.} =
  var entry = NoPasteEntry()
  noPaste.db.select(entry, "NoPasteEntry.noPasteId = ?", noPasteId)
  entry.name = name
  entry.content = content
  noPaste.db.update(entry)

proc delete(noPaste: NoPaste, noPasteId: NoPasteId) =
  var entry = NoPasteEntry()
  noPaste.db.select(entry, "NoPasteEntry.noPasteId = ?", noPasteId)
  noPaste.deleteUploadFile(entry.nopasteId)
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
proc getUploadUri(entry: NoPasteEntry): string =
  "/static/uploads" / entry.nopasteId / entry.uploadFile

proc computeHowLongValidStr(dateCreation, howLongValid: float): string {.inline.} =
  result = ""
  try:
    result = $fromUnixFloat(dateCreation + howLongValid.float)
  except:
    result = $fromUnixFloat(int32.high.float) # float.high is invalid here, does not matter, we just need a very high number

proc computeFromTo(entry: NoPasteEntry): string =
  if entry.volatile: return "volatile (one get)"
  $entry.dateCreation.fromUnixFloat() & " until " & computeHowLongValidStr(entry.dateCreation, entry.howLongValid.float)

proc renderFilePreview(entry: NoPasteEntry): VNode =
  if entry.uploadFile.len == 0: return
  let ext = entry.uploadFile.splitFile().ext.toLowerAscii()
  result = buildHtml(tdiv(id="preview")):
    case ext
    of ".gif", ".png", ".jpeg", ".jpg":
      img(src = entry.getUploadUri())
    of ".mp3", ".ogg", ".wav", ".opus":
      audio(controls = "controls"):
        source(src = entry.getUploadUri())
    of ".mp4":
      video(controls = "controls"):
        source(src = entry.getUploadUri())
    of ".txt", ".json", ".jsonl", ".pdf":
      iframe(src = entry.getUploadUri())
    else:
      discard

proc render(ctx: Context, entry: NoPasteEntry): VNode =
  result = buildHtml(tdiv):
    tdiv(id = "meta"):
      h1:
        text entry.name
      tdiv:
        text entry.noPasteId & " " & computeFromTo(entry)
      tdiv(id = "qr")
      script():
       verbatim """
var qrcode = new QRCode(document.getElementById("qr"), {
	text: window.location.href,
	width: 128,
	height: 128,
	colorDark : "#000000",
	colorLight : "#ffffff",
	correctLevel : QRCode.CorrectLevel.H
});
"""
      tdiv:
        a(href = "/raw/" & entry.noPasteId, class = "raw"):
          text "[raw]"
        a(href = "/edit/" & entry.noPasteId, class = "edit"):
          text "[edit]"
        if ctx.loggedIn:
          a(href = "/delete/" & entry.noPasteId, class="delete"):
            text "[delete]"
    if entry.uploadFile.len > 0:
      tdiv(id = "uploads"):
        a(href = entry.getUploadUri()):
          text entry.uploadFile
        entry.renderFilePreview()
    hr()
    tdiv(id = "content"):
      pre:
        text entry.content

proc render(ctx: Context, noPasteEntries: seq[NoPasteEntry]): VNode =
  result = buildHtml(tdiv):
    for entry in noPasteEntries:
      tdiv(class="entry"):
        a(href = "/get/" & entry.noPasteId, class="get"):
          text fmt"-> {entry.name} " & computeFromTo(entry)
        a(href = "/raw/" & entry.noPasteId, class="raw"):
          text "[raw]"
        a(href = "/edit/" & entry.noPasteId, class="edit"):
          text "[edit]"
        if entry.uploadFile.len > 0:
          a(href = noPaste.getUploadUri(entry), class="download"):
            text "[download]"
        a(href = "/delete/" & entry.noPasteId, class="delete"):
          text "[delete]"

proc renderMenu(ctx: Context): VNode =
  result = buildHtml(tdiv(id="menu")):
    if ctx.loggedIn():
      a(href = "/"): text "home"
      a(href = "/add"): text "add"
      a(href = "/addshortlink"): text "shortlinks"
      a(href = "/logout"): text "logout(" & ctx.session.getOrDefault("username") & ")"
      a(href = "/deleteAll", class = "delete"): text "deleteAll" # onclick="return confirm('Are you sure?')"  # TODO onlick does not work on karax native... Error: undeclared identifier: 'addEventHandler'
    else:
      a(href = "/login"): text "login"

proc renderLogin(): Vnode =
  result = buildHtml(tdiv(id="login")):
    form(`method` = "post"):
      ul:
        li: input(name = "username", placeholder = "username")
        li: input(name = "password", placeholder = "password", `type` = "password")
        li: input(`type` = "submit", value = "login")

proc master(ctx: Context, content: VNode): VNode =
  result = buildHtml(html):
    head:
      link(rel="stylesheet", href="/static/style.css")
      meta(`name`="viewport", content="width=device-width, initial-scale=1.0")
      script(src = "/static/qrcode.min.js")
    body:
      renderMenu(ctx)
      if ctx.hasFlash:
        tdiv(id = "flash"):
          text ctx.popFlash
      content

proc home*(noPaste: NoPaste, ctx: Context) {.async.} =
  resp $master(ctx, render(ctx, noPaste.getAllNopasteEntry()))

template getFormParam(ctx: Context, key: string): string =
  ctx.request.formParams.data[key].body

template hasUploadedFile(ctx: Context, key: string): bool =
  ctx.request.formParams.data.hasKey(key)

func empty(entry: NoPasteEntry): bool =
  result = (entry.name.len == 0) and (entry.content.len == 0) and (entry.uploadFile.len == 0)

proc login*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  case ctx.request.reqMethod
  of HttpPost:
    let username = ctx.getFormParam("username")
    let password = ctx.getFormParam("password")
    if username == USERNAME and password == PASSWORD:
      ctx.session["login"] = $true
      ctx.session["username"] = username
    else:
      ctx.setFlash("wrong credentials")
    resp redirect("/", Http302)
  of HttpGet:
    resp $master(ctx, renderLogin())
  else:
    discard

proc logout*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  ctx.session.clear()
  resp redirect("/", Http302)

proc edit*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  var entryOpt = noPaste.getNopasteEntryById(noPasteId)
  if entryOpt.isNone:
    resp "404 :(", Http404
    return
  var entry = entryOpt.get()
  case ctx.request.reqMethod
  of HttpPost:
    let name = ctx.getFormParam("name")
    let content = ctx.getFormParam("content")
    noPaste.updateNopasteEntryById(noPasteId, name, content)
    resp redirect("/", Http302)
  of HttpGet:
    var vnode = buildHtml(tdiv):
      form(`method` = "post", enctype = "multipart/form-data"):
        input(name = "name", id = "name", placeholder = "name", value = entry.name): discard
        textarea(name = "content", id = "content", placeholder = "content"):
          text entry.content
        button(id="mysubmit"):
          text "edit"
    resp $master(ctx, vnode)
  else: discard

proc addshortlink*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  case ctx.request.reqMethod
  of HttpPost:
    discard
    let linkname = ctx.getFormParam("linkname").strip()
    let target = ctx.getFormParam("target").strip()
    if linkname.len > 0 and target.len > 0:
      var shortlink = ShortlinkEntry(
        shortlinkId: linkname,
        target: target
      )
      try:
        noPaste.db.insert(shortlink)
        ctx.setFlash("shortlink added!")
      except:
        ctx.setFlash("could NOT add shortlink!: " & getCurrentExceptionMsg())
    else:
      ctx.setFlash("linkname and target must be set. Nothing added...")
    resp redirect("/addshortlink", Http302)
  of HttpGet:
    var vnode = buildHtml(tdiv):
      form(`method` = "post", enctype = "multipart/form-data"):
        input(name = "linkname", id = "linkname", placeholder = "linkname"):
          discard
        input(`name` = "target", id = "target", placeholder = "target")
        button(id="mysubmit"):
          text "submit"
        table:
          tr:
            th:
              text "name"
            th:
              text "target"
            th:
              text "actions"
          for shortlinkEntry in noPaste.getAllShortlinksEntry():
            tr:
              td:
                a(href = "/s/" & shortlinkEntry.shortlinkId):
                  text shortlinkEntry.shortlinkId
              td:
                a(href = shortlinkEntry.target):
                  text shortlinkEntry.target
              td:
                a(href = "/deleteShortlink/" & shortlinkEntry.shortlinkId):
                  text "[delete]"

    resp $master(ctx, vnode)
  else:
    discard

proc deleteShortlink*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  let shortlinkId = ctx.getPathParams("shortlink", "")
  var entry = ShortlinkEntry()
  noPaste.db.select(entry, "ShortlinkEntry.shortlinkId = ?", shortlinkId)
  noPaste.db.delete(entry)
  resp redirect("/addshortlink")

proc followShortlink*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  let shortlink = ctx.getPathParams("shortlink", "")
  var error = true
  if shortlink.len > 0:
    let shortlinkOpt = noPaste.getShortlinkEntryById(shortlink)
    if shortlinkOpt.isSome:
      error = false
      resp redirect(shortlinkOpt.get().target, Http302)
  if error:
    resp "Not Found", Http404

proc add*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  case ctx.request.reqMethod
  of HttpPost:
    var howLongValid = 0
    var volatile = false
    try:
      howLongValid = parseInt(ctx.getFormParam("howLongValid"))
    except:
      echo getCurrentExceptionMsg()
      resp "howLongValid not valid ;)", Http400
      return
    if howLongValid == -1: volatile = true
    var entry = newNoPasteEntry(ctx.getFormParam("name"), ctx.getFormParam("content"), howLongValid = howLongValid, volatile = volatile)

    if ctx.hasUploadedFile("upload"):
      try:
        var file = ctx.getUploadFile("upload")
        let entryFolder = uploadDir / entry.noPasteId
        if not dirExists(entryFolder): createDir(entryFolder)
        file.save(dir = entryFolder)
        entry.uploadFile = file.filename
      except:
        echo "upload file not saved / or none there"
        echo getCurrentExceptionMsg()
    if not entry.empty():
      noPaste.db.insert(entry)
      ctx.setFlash("entry added!")
    # resp redirect("/get/" & entry.noPasteId) # cannot do this because of volatile, would be deleted instantly
    resp redirect("/")
  of HttpGet:
    var vnode = buildHtml(tdiv):
      form(`method` = "post", enctype = "multipart/form-data"):
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
        input(`name` = "upload", id = "upload", `type` = "file")
        button(id="mysubmit"):
          text "submit"
    resp $master(ctx, vnode)
  else:
    discard

proc deleteIfVolatile(noPaste: NoPaste, entry: var NoPasteEntry) {.gcsafe.} =
  if entry.volatile:
    noPaste.deleteUploadFile(entry.noPasteId)
    noPaste.db.delete(entry)

proc raw*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  var entryOpt = noPaste.getNopasteEntryById(noPasteId)
  if entryOpt.isSome():
    ctx.response.setHeader("content-type", "text/plain")
    resp entryOpt.get().content
    noPaste.deleteIfVolatile(entryOpt.get())
  else:
    resp("404 :( ", Http404)

proc get*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  var entryOpt = noPaste.getNopasteEntryById(noPasteId)
  if entryOpt.isSome():
    resp $master(ctx, render(ctx, entryOpt.get()))
    noPaste.deleteIfVolatile(entryOpt.get())
  else:
    resp("404 :(", Http404)

proc delete*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  let noPasteId = ctx.getPathParams("noPasteId", "")
  noPaste.delete(noPasteId)
  ctx.setFlash("entry deleted: " & $noPasteId)
  resp redirect("/")

proc deleteAll*(noPaste: NoPaste, ctx: Context) {.async, gcsafe.} =
  noPaste.deleteAllEntries
  ctx.setFlash("all entries deleted")
  resp redirect("/")

proc doCleanup(noPaste: NoPaste) {.async, gcsafe.} =
  while true:
    noPaste.deleteExpiredEntries()
    await sleepAsync(initDuration(minutes = 5).inMilliseconds().int)

proc loginRequired*(loginUrl = "/login"): HandlerAsync =
  result = proc(ctx: Context) {.async.} =
    if not ctx.loggedIn(): #and (ctx.request.path() != loginUrl): # TODO crash
      resp redirect(loginUrl, Http307)
    else:
      await switch(ctx)

when ENABLE_DEFLATE:
  import miniz
  proc deflateMiddleware*(): HandlerAsync =
    ## Compresses the response
    result = proc(ctx: Context) {.async.} =
      await switch(ctx)
      if ctx.request.headers.hasKey("Accept-Encoding"):
        let encodings = ctx.request.headers.getOrDefault("Accept-Encoding")
        if encodings.find("deflate") != -1:
          ctx.response.headers.add("Content-Encoding", "deflate")
          ctx.response.headers.add("X-org-size", $ctx.response.body.len) # just for me to see the difference
          ctx.response.body = ctx.response.body.compress()
          ctx.response.headers.add("X-compressed-size", $ctx.response.body.len) # just for me to see the difference

proc main() =
  var debug = true
  if defined release: debug = false
  var noPaste = newNoPaste()
  noPaste.init()
  var middlewares: seq[HandlerAsync] = @[]
  let settings = newSettings(secretKey = secretKey, appName = "NoPaste", debug = debug)
  if debug:
    middlewares.add debugRequestMiddleware()
  # if true:
  #   middlewares.add loginRequired()
  middlewares.add sessionMiddleware(settings, path = "/")
  middlewares.add staticFileMiddleware(["static"])
  when ENABLE_DEFLATE:
    middlewares.add deflateMiddleware()
  var app = newApp(
    settings = settings,
    errorHandlerTable=newErrorHandlerTable(),
    middlewares = middlewares
  )

  # Routes for nopaste
  app.addRoute("/", proc (ctx: Context): Future[void] {.gcsafe.} = home(noPaste, ctx), @[HttpGet, HttpPost], middlewares = @[loginRequired()])
  app.addRoute("/login", proc (ctx: Context): Future[void] {.gcsafe.} = login(noPaste, ctx), @[HttpGet, HttpPost])
  app.addRoute("/logout", proc (ctx: Context): Future[void] {.gcsafe.} = logout(noPaste, ctx), @[HttpGet, HttpPost], middlewares = @[loginRequired()])
  app.addRoute("/add", proc (ctx: Context): Future[void] {.gcsafe.} = add(noPaste, ctx), @[HttpGet, HttpPost], middlewares = @[loginRequired()])
  app.addRoute("/edit/{noPasteId", proc (ctx: Context): Future[void] {.gcsafe.} = edit(noPaste, ctx), @[HttpGet, HttpPost], middlewares = @[loginRequired()])
  app.addRoute("/raw/{noPasteId}", proc (ctx: Context): Future[void] {.gcsafe.} = raw(noPaste, ctx), HttpGet)
  app.addRoute("/get/{noPasteId}", proc (ctx: Context): Future[void] {.gcsafe.} = get(noPaste, ctx), HttpGet)
  app.addRoute("/delete/{noPasteId}", proc (ctx: Context): Future[void] {.gcsafe.} = delete(noPaste, ctx), HttpGet, middlewares = @[loginRequired()])
  app.addRoute("/deleteAll", proc (ctx: Context): Future[void] {.gcsafe.} = deleteAll(noPaste, ctx), HttpGet, middlewares = @[loginRequired()])

  # Routes for shortlink
  app.addRoute("/addshortlink", proc (ctx: Context): Future[void] {.gcsafe.} = addshortlink(noPaste, ctx), @[HttpGet, HttpPost], middlewares = @[loginRequired()])
  app.addRoute("/deleteShortlink/{shortlink}", proc (ctx: Context): Future[void] {.gcsafe.} = deleteShortlink(noPaste, ctx), @[HttpGet, HttpPost], middlewares = @[loginRequired()])
  app.addRoute("/s/{shortlink}", proc (ctx: Context): Future[void] {.gcsafe.} = followShortlink(noPaste, ctx), HttpGet)
  asyncCheck noPaste.doCleanup()
  app.run()


when isMainModule:
  main()