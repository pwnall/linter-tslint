{CompositeDisposable} = require 'atom'
path = require 'path'
fs = require 'fs'
requireResolve = require 'resolve'

TSLINT_MODULE_NAME = 'tslint'

trim = str -> str.replace /^\s|\s$/g, ''

module.exports =

  config:
    tslintPath:
      type: 'string'
      title: ''
      default: 'Local path or ' +
        'http url (http:// or https:// schemas) to tslint.json'
    rulesDirectory:
      type: 'string'
      title: 'Custom rules directory (absolute path)'
      default: ''
    useLocalTslint:
      type: 'boolean'
      title: 'Try using the local tslint package (if exist)'
      default: true

  rulesDirectory: ''
  tslintCache: new Map
  tslintDef: null
  tslintJSON: null
  useLocalTslint: true

  activate: ->
    require('atom-package-deps').install('linter-tslint')
    @subscriptions = new CompositeDisposable
    @scopes = ['source.ts', 'source.tsx']
    @subscriptions.add atom.config.observe 'linter-tslint.rulesDirectory',
      (dir) =>
        dir = trim dir

        if dir and path.isAbsolute(dir)
          fs.stat dir, (err, stats) =>
            @rulesDirectory = if stats?.isDirectory() then dir else ''
          return
        @rulesDirectory = ''

    @subscriptions.add atom.config.observe 'linter-tslint.useLocalTslint',
      (use) =>
        @tslintCache.clear()
        @useLocalTslint = use

    @subscriptions.add atom.config.observe 'linter-tslint.tslintPath',
      (tslintPath) =>
        tslintPath = trim tslintPath

        if tslintPath.test /^https?:\/\/.+/
          fetch(tslintPath)
            .then(response -> response.json)
            .then(json => @tslintJSON = json)
            .catch(err -> return)
          return

        if path.isAbsolute(tslintPath)
          fs.stat tslintPath, (err, stats) ->
            # todo

          return

        @tslintJSON = null

  deactivate: ->
    @subscriptions.dispose()

  getLinter: (filePath) ->
    basedir = path.dirname filePath
    linter = @tslintCache.get basedir
    if linter
      return Promise.resolve(linter)

    if @useLocalTslint
      return @getLocalLinter(basedir)

    @tslintCache.set basedir, @tslintDef
    Promise.resolve(@tslintDef)

  getLocalLinter: (basedir) ->
    new Promise (resolve, reject) =>
      requireResolve TSLINT_MODULE_NAME, { basedir },
        (err, linterPath, pkg) =>
          if not err and pkg?.version.startsWith '3.'
            linter = require linterPath
          else
            linter = @tslintDef
          @tslintCache.set basedir, linter
          resolve(linter)

  provideLinter: ->
    @tslintDef = require TSLINT_MODULE_NAME

    provider =
      grammarScopes: @scopes
      scope: 'file'
      lintOnFly: true
      lint: (textEditor) =>
        filePath = textEditor.getPath()
        text = textEditor.getText()

        @getLinter(filePath).then (Linter) =>
          configurationPath = Linter.findConfigurationPath null, filePath
          configuration = Linter.loadConfigurationFromPath configurationPath

          rulesDirectory = configuration.rulesDirectory
          if rulesDirectory
            configurationDir = path.dirname configurationPath
            if not Array.isArray rulesDirectory
              rulesDirectory = [rulesDirectory]
            rulesDirectory = rulesDirectory.map (dir) ->
              path.join configurationDir, dir

            if @rulesDirectory
              rulesDirectory.push @rulesDirectory

          linter = new Linter filePath, text,
            formatter: 'json'
            configuration: configuration
            rulesDirectory: rulesDirectory

          lintResult = linter.lint()

          if not lintResult.failureCount
            return []

          lintResult.failures.map (failure) ->
            startPosition = failure.getStartPosition().getLineAndCharacter()
            endPosition = failure.getEndPosition().getLineAndCharacter()
            {
              type: 'Warning'
              text: "#{failure.getRuleName()} - #{failure.getFailure()}"
              filePath: path.normalize failure.getFileName()
              range: [
                [ startPosition.line, startPosition.character],
                [ endPosition.line, endPosition.character]
              ]
            }
