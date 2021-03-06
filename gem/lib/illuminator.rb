require "illuminator/version"

require "illuminator/automation-builder"
require "illuminator/automation-runner"
require "illuminator/argument-parsing"
require "illuminator/device-installer"
require "illuminator/build-artifacts"
require "illuminator/host-utils"
require "illuminator/xcode-utils"
require "illuminator/options"


module Illuminator

  class Framework

    def self.willClean options
      return true if options.illuminator.clean.derived
      return true if options.illuminator.clean.artifacts
      return true if options.illuminator.clean.xcode
      return false
    end

    def self.cleanCountdown
      countdown = "3....2....1...."
      print "Cleaning in ".yellow
      countdown.split("").each do |c|
        print c.yellow
        sleep(0.2)
      end
      print "\n"
    end

    def self.validateOptions(options)
      noproblems = true

      # so we can call BS on the user
      bs = lambda do |message|
        puts message.red
        noproblems = false
      end

      # some things to check
      things = {
        "Build artifacts directory" => options.buildArtifactsDir,
      }

      # now check them
      things.each { |k, v| bs.call "#{k} was not specified" if v.nil? }

      # fail quickly if simulator device and/or version are wrong
      if options.illuminator.hardwareID.nil?
        device = options.simulator.device
        version = options.simulator.version
        devices = XcodeUtils.instance.getSimulatorDeviceTypes()
        versions = XcodeUtils.instance.getSimulatorRuntimes()


        unless devices.include? device
          bs.call "Specified simulator device '#{device}' does not appear to be installed -  options are #{devices}"
        end

        unless versions.include? version
          bs.call "Specified simulator iOS version '#{version}' does not appear to be installed -  options are #{versions}"
        end

      end

      # check paths
      if options.illuminator.task.automate
        bs.call "Implementation was not specified" if options.javascript.implementation.nil?

        if options.javascript.testPath.nil?
          bs.call "Javascript test definitions file was not specified"
        else
          unless File.exists? options.javascript.testPath
            bs.call "Could not find specified javascript test definitions file at '#{options.javascript.testPath}'"
          end
        end
      end

      return noproblems
    end

  end



  def self.runWithOptions(originalOptions)

    options = Options.new(originalOptions.to_h) # immediately create a copy of the options, because we may mangle them
    Illuminator::BuildArtifacts.instance.setRoot options.buildArtifactsDir

    hardwareID = options.illuminator.hardwareID
    appName    = options.xcode.appName

    # validate some inputs
    return false unless Framework.validateOptions(options)

    # do any initial cleaning
    cleanDirs = {
      HostUtils.realpath("~/Library/Developer/Xcode/DerivedData") => options.illuminator.clean.derived,
      Illuminator::BuildArtifacts.instance.root(true)             => options.illuminator.clean.artifacts,
    }
    Framework.cleanCountdown if Framework.willClean(options) and (not options.illuminator.clean.noDelay)
    cleanDirs.each do |d, doClean|
      dir = HostUtils.realpath d
      if doClean
        puts "Illuminator cleanup: removing #{dir}"
        FileUtils.rmtree dir
      end
    end

    # Initialize builder and build
    if (not options.instruments.appLocation.nil?)
      puts "Skipping build because appLocation was provided".yellow if options.illuminator.task.build
      options.instruments.appLocation = HostUtils::realpath(options.instruments.appLocation)
    elsif (not options.illuminator.task.build)
      options.instruments.appLocation = Illuminator::BuildArtifacts.instance.appLocation(appName) # assume app is here
    else
      builder = AutomationBuilder.new
      builder.projectDir = options.xcode.projectDir
      builder.project    = options.xcode.project
      builder.scheme     = options.xcode.scheme
      builder.workspace  = options.xcode.workspace
      builder.doClean    = options.illuminator.clean.xcode
      unless options.xcode.environmentVars.nil?
        options.xcode.environmentVars.each { |name, value| builder.addEnvironmentVariable(name, value) }
      end

      # if app name is not specified, make sure that we will only have one to run
      XcodeUtils.removeExistingApps(Illuminator::BuildArtifacts.instance.xcode) if appName.nil?
      if builder.buildForAutomation(options.xcode.sdk, hardwareID)
        puts 'Build succeded'.green
        options.instruments.appLocation = Illuminator::BuildArtifacts.instance.appLocation(appName)
      else
        puts 'Build failed, check logs for results'.red
        exit builder.exitCode
      end
    end

    return true unless options.illuminator.task.automate

    # Install on real device
    unless hardwareID.nil?
      DeviceInstaller.instance.installOnDevice(options.instruments.appLocation, hardwareID)
    end

    # Initialize automation
    runner = AutomationRunner.new
    runner.appName = appName
    runner.cleanup
    return runner.runWithOptions(options)

  end

  # overrideOptions is a lambda function that acts on the options object
  def self.reRun(configPath, overrideOptions = nil)

    # load config from supplied path
    jsonConfig = IO.read(configPath)

    # process any overrides
    options = overrideOptions.(Illuminator::Options.new(JSON.parse(jsonConfig))) unless overrideOptions.nil?

    return runWithOptions options
  end


end
