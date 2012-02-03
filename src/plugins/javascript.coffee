_ = require 'underscore'
fs = require 'fs'
path = require 'path'

{Brewer, Source} = require '..'
util = require '../util'
{Bundle} = require '../bundle'
{finished} = require '../command'

@JavascriptBrewer = class JavascriptBrewer extends Brewer
  @types = ['js', 'javascript']
  constructor: (options) ->
    super options
    _.defaults options, compress: true
    {compress, @build, @bundles} = options
    @bundles = JSON.parse fs.readFileSync @bundles if _.isString @bundles
    
    if compress
      @compressedFile = _.template if _.isString compress 
        compress
      else 
        "<%= filename %>.min.js"
  


@JavascriptBundle = class JavascriptBundle extends Bundle
  sourcePath: (i) ->
    file = if i < @files.length then @files[i] else @file
    src = @brewer.source(file)
    path.join (src.js_path ? src.path), util.changeExtension file, '.js'
  
  compress: (cb) ->
    {parser, uglify} = require 'uglify-js'
    {gen_code, ast_squeeze, ast_mangle} = uglify
    util.newer (cmpFile = @compressedFile), (buildPath = @buildPath())
    , (err, newer) =>
      if newer
        finished 'Unchanged', cmpFile
        return cb(cmpFile)
      fs.readFile buildPath, 'utf-8', (err, data) =>
        code = gen_code ast_squeeze parser.parse data
        fs.writeFile cmpFile, code, 'utf-8', ->
          finished 'Compressed', cmpFile
          cb cmpFile
      
      
    
  

@JavascriptSource = class JavascriptSource extends Source
  @Bundle = JavascriptBundle
  @types = ['js', 'javascript']
  @ext = JavascriptBundle.ext = '.js'
  @header = /^\/\/\s*(?:import|require)\s+([a-zA-Z0-9_\-\,\.\[\]\{\}\u0022/ ]+)/m


Source.extend JavascriptSource
Brewer.extend JavascriptBrewer
