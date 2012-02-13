fs = require 'fs'
{join, basename, resolve} = require 'path'
crypto = require 'crypto'
vm = require 'vm'
{spawn} = require 'child_process'
{EventEmitter} = require 'events'
temp = require 'temp'
semver = require 'semver'
request = require 'request'
_ = require 'underscore'
coffeescript = require 'coffee-script'

{chdir} = process
{info, debug} = require './command'
move = fs.renameSync

validVersionSpec = (vsn) ->
  return (
    semver.valid(vsn) or 
    semver.validRange(vsn) or 
    vsn is 'latest'
  )


class InvalidChecksum extends Error
  constructor: (@formula, @url) ->
    @message = "Invalid checksum for #{formula.name} (#{version}), downloaded from #{url}"
    @name = 'InvalidChecksum'
  

class Installer extends EventEmitter
  constructor: (@formula, @project, @version="latest") ->
  
  
  context: ->
    include: (src, opts, cb) =>
      [cb, opts] = [opts, {}] if _.isFunction opts
      info "Moving #{src} into vendor folder"
      root = @project.vendorlibs.root
      (spawn 'cp', ['-fpLR', src, root]).on 'end', ->
        if (dest = opts.rename)?
          move (join(root, d) for d in [basename(src), dest])...
        cb.call @
      
    
    deflate: (file, ext, cb) =>
      flags = _.reject ext.split('.'), (f) -> f is ''
      
      if flags[0] is 'tar'
        flag = {'bz2': 'j', 'gz': 'z'}[flags[1]] ? ''
        child = spawn 'tar', ['-xvf'+flag, file]
      else if flags[0] is 'zip'
        child = spawn 'unzip', [file]
      else return cb
      
      info "Deflating #{file}"
      child.on 'end', =>
        fs.unlink file, =>
          fs.readdir '.', (err, files) =>
            if files.length == 1 and fs.statSync(files[0]).isDirectory()
              chdir files[0]
            cb.call @
      
    
  
  fetch: (cb) ->
    formula = @formula
    vsn = @version
    temp.mkdir (err, @temp) =>
      cb new Error err if err
      chdir tempdir
      url = @formula.url vsn
      download = join tempdir, vsn
      info "Downloading #{url} to #{download}"
      req = request url
      ws = fs.createWriteStream download
      req.on 'error', (err) -> cb(err)
      ws.on 'error', (err) -> cb(err)
      req.pipe ws
      
      if (checksum = @formula.checksum)?
        md5 = crypto.createHash 'md5'
        req.on 'data', (data) -> md5.update data
      
      req.on 'end', ->
        if checksum? and checksum isnt md5.digest 'hex'
          cb new InvalidChecksum formula, url
        else cb(null, download)
    
  
  install: (cb) ->
    @fetch (err, download) =>
      if err? then cb(err)
      else @formula.installer.call @context(), download, cb
  

class Formula
  @formattedVersion: (vsn) ->
    return vsn if vsn == 'latest'
    if (version = semver.clean vsn)?
      [v, tag] = version.split '-'
      [major, minor, patch] = v.split '.'
      {tag, major, minor, patch, version, toString: -> version}
    else
      throw new Error "The supplied version is not correctly formatted: '#{vsn}'"
  
  
  constructor: (@name) ->
    @requirements = []
    @optionals = []
  
  
  valid: -> @urls? and @installer?
  url: (vsn) ->
    # Proxy the list of available versions and the
    # defined urls getter
    versions = @versions
    urls = @urls
    vsn = @latest if @latest and vsn is 'latest'
    
    if _.isFunction urls
      # If urlGetter is a function, we match 'latest'
      # to the latest available version and pass it over
      
      vsn = 'X.X.X' if vsn is 'latest'
      urls Formula.formattedVersion semver.maxSatisfying versions, vsn
    else
      # urlGetter can also be a hash, mapping semantic versions
      # or version ranges to either a string or a function
      version = if vsn is 'latest' then 'X.X.X' else vsn
      version = semver.maxSatisfying versions, version
      if vsn is 'latest' and 'latest' of urls
        match = urls.latest
      else
        match = _.find urls, (url, ver) ->
          return false if ver is 'latest'
          semver.satisfies version, ver
        return false unless match?
      
      if _.isFunction match
        match = match Formula.formattedVersion version
      match
  
  
  context: ->
    homepage: (@homepage) =>
    doc: (@doc) =>
    install: (@installer) =>
    latest: (@latest) =>
    md5: (@checksum) =>
    
    versions: (versions...) =>
      @versions ?= []
      @versions.push versions...
    
    urls: (map) =>
      if _.isFunction map
        @urls = map
      else if _.isObject map
        for version, value of map
          unless validVersionSpec(version)
            throw new Error("Invalid version specifier")
          if !@urls? or _.isFunction @urls
            @urls = {}
          @urls[version] = value
    
    require: (formulae...) =>
      @requirements.push(formula) for formula in formulae when not _.include(@requirements, formula)
    
    optional: (formulae...) =>
      @optionals.push(formula) for formula in formulae when not _.include(@optionals, formula)
    
  

class Catalog
  constructor: (@dirpath=resolve(__dirname, '..', 'formula')) ->
    @path = join dirpath, 'catalog.json'
  
  
  readFile: ->
    @formulae = JSON.parse fs.readFileSync @path, 'utf-8'
  
  writeFile: ->
    fs.writeFileSync @path, JSON.stringify(@formulae, null, 4), 'utf-8'
  
  exists: -> path.exists @path
  
  parsedir: (cb) ->
    
  

_.extend exports,

  Installer: Installer
  Formula: Formula
  InvalidChecksum: InvalidChecksum
  
  formulae: (file) ->
    ctx = _.clone global
    ctx.formulae = {}
    
    ctx.formula = (name, body) ->
      ctx.formulae[name] = formula = new Formula(name)
      body.call formula.context()
    
    coffeescript.eval fs.readFileSync(file, 'utf-8'), 
      sandbox: vm.createContext(ctx)
      filename: file
    
    ctx.formulae
  
