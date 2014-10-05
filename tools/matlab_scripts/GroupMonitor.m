classdef GroupMonitor < handle
    %
    % Version 10/2/2014
    % Author: Michael Beyeler <mbeyeler@uci.edu>
    
    %% PROPERTIES
    % public
    properties (SetAccess = private)
        name;               % group name
        resultsFolder;      % results folder
        
        errorMode;          % program mode for error handling
        supportedErrorModes;% supported error modes
        supportedPlotTypes; % cell array of supported plot types
    end
    
    % private
    properties (Hidden, Access = private)
        spkObj;             % SpikeReader object
        spkFilePrefix;      % spike file prefix, e.g. "spk"
        spkFileSuffix;      % spike file suffix, e.g. ".dat"
        spkData;
        spkFrameDur;
        
        simLength;
        grid3D;
        
        plotTimeBinSize;
        plotType;
        plotAbortPlotting;
        
        errorFlag;          % error flag (true if error occured)
        errorMsg;           % error message
        
    end
    
    
    %% PUBLIC METHODS
    methods
        function obj = GroupMonitor(name, resultsFolder, errorMode)
            obj.name = name;
            obj.unsetError()
            obj.loadDefaultParams();
            
            if nargin<3
                obj.errorMode = 'standard';
            else
                if ~obj.isErrorModeSupported(errorMode)
                    obj.throwError(['errorMode "' errorMode '" is ' ...
                        'currently not supported. Choose from the ' ...
                        'following: ' ...
                        strjoin(obj.supportedErrorModes,', ') ...
                        '.'], 'standard')
                    return
                end
                obj.errorMode = errorMode;
            end
            if nargin<2
                obj.resultsFolder = '';
            else
                obj.resultsFolder = resultsFolder;
            end
            if nargin<1
                obj.throwError('No group name given.');
                return
            end
            
            % init SpikeReader
            obj.initSpikeReader();
            
            % set default plot type according to Grid3D
            obj.setPlotType( obj.getDefaultPlotType() );
        end
                
        function delete(obj)
            % destructor, implicitly called
            clear obj.spkObj;
        end
        
        function plotType = getDefaultPlotType(obj)
            if prod(obj.grid3D)<=0
                obj.throwError(['Must load data before setting ' ...
                    'default plot type'])
            end
            
            % find dimensionality of Grid3D
            % i.e., Nx1x1 is 1D, NxMx1 is 2D, NxMxL is 3D
            dims = 3-sum(obj.grid3D==1);
            if dims==1
                % 1D layout prefers raster
                plotType = 'raster';
            elseif dims==2
                % 2D layout prefers raster
                plotType = 'heatmap';
            else
                % \TODO add more logic
                plotType = 'raster';
            end
        end
        
        function [errFlag,errMsg] = getError(obj)
            % [errFlag,errMsg] = getError() returns the current error
            % status.
            % If an error has occurred, errFlag will be true, and the
            % message can be found in errMsg.
            errFlag = obj.errorFlag;
            errMsg = obj.errorMsg;
        end
        
        function spkFile = getSpikeFileName(obj)
            % spkFile = AM.getSpikeFileName() returns the name of the
            % spike file according to specified prefix and suffix.
            % Prefix and suffix can be set using AM.setSpikeFileAttributes.
            spkFile = [ obj.resultsFolder ... % the results folder
                filesep ...                   % platform-specific separator
                obj.spkFilePrefix ...         % something like 'spk_'
                obj.name ...                  % the name of the group
                obj.spkFileSuffix ];          % something like '.dat'
        end
                
        function hasValid = hasValidSpikeFile(obj)
            % hasValid = hasValidSpikeFile() determines whether a valid
            % spike file can be found for the group.
            % If no file can be found, you need to update prefix and suffix
            % of the spike file name by calling the GroupMonitor function
            % setSpikeFileAttributes(prefix,suffix).
            spkFile = obj.getSpikeFileName();
            SR = SpikeReader(spkFile, false, 'silent');
            [errFlag,~] = SR.getError();
            hasValid = ~errFlag;
        end
        
        function loadDataForPlotting(obj, plotType, plotTimeBinSize)
            % private function to prepare data for plotting
            if nargin<3,plotTimeBinSize=obj.plotTimeBinSize;end
            if nargin<2,plotType=obj.plotType;end
            obj.unsetError()
            
            % parse plot type and make it permanent
            if strcmpi(plotType,'default')
                % find default type based on Grid3D
                plotType = obj.getDefaultPlotType();
            elseif isempty(plotType)
                % use current plot type
                plotType = obj.plotType;
            end
            obj.setPlotType(plotType);
            
            % if plotting has not changed since last time, we do not need
            % to do any more work, just reload data from private property
            if sum(obj.plotTimeBinSize==plotTimeBinSize) && ~isempty(obj.spkData)
                return
            end
            
            % if plot type or bin has changed, we need to re-read and
            % re-format the spike data
            if strcmpi(obj.plotType,'heatmap')
                % heat map uses user-set frameDur for both binning and
                % plotting
                spkBuffer = obj.spkObj.readSpikes(plotTimeBinSize);
                
                % reshape according to group dimensions
                numFrames = size(spkBuffer,1);
                spkBuffer = reshape(spkBuffer, numFrames, ...
                    obj.grid3D(1), obj.grid3D(2), ...
                    obj.grid3D(3));
                
                % reshape for plotting
                % \TODO consider the case 1xNxM and Nx1xM
                spkBuffer = permute(spkBuffer,[3 2 4 1]); % Matlab: Y, X
                spkBuffer = reshape(spkBuffer,obj.grid3D(2),[],numFrames);
            elseif strcmpi(obj.plotType,'raster')
                % raster uses user-set frameDur just for plotting
                % binning is not required, use AER instead
                spkBuffer = obj.spkObj.readSpikes(-1);
            else
                obj.throwError(['Unrecognized plot type "' obj.plotType '".'])
                return
            end
            
            % store spike data
            obj.spkData = spkBuffer;
        end
        
        function plot(obj, frames, plotType, frameDur, stepFrames, fps, dispFrameNr)
            if nargin<7,dispFrameNr=true;end
            if nargin<6,fps=5;end
            if nargin<5,stepFrames=false;end
            if nargin<4,frameDur=obj.plotTimeBinSize;end
            if nargin<3,plotType=obj.plotType;end
            if nargin<2,frames=-1;end
            obj.unsetError()
            
            % reset abort flag, set up callback for key press events
            obj.plotAbortPlotting = false;
            set(gcf,'KeyPressFcn',@obj.pauseOnKeyPressCallback)
            
            % load data and reshape for plotting if necessary
            obj.loadDataForPlotting(plotType, frameDur);
            
            % set range of frames to full stimulus
            if isempty(frames) || frames==-1
                frames = 1:ceil(obj.spkObj.getStimulusLengthMs()/frameDur);
            end
            
            % display frame in specified axes
            for i=frames
                if obj.plotAbortPlotting
                    % user pressed button to quit plotting
                    obj.plotAbortPlotting = false;
                    close;
                    return
                end
                
                obj.plotFrame(i,plotType,frameDur,dispFrameNr);
                drawnow

                % wait for button press or pause
                if stepFrames
                    waitforbuttonpress;
                else
                    pause(1.0/fps)
                end
            end
        end
        
        function plotFrame(obj, frameNr, plotType, frameDur, dispFrameNr)
            % frame duration cannot be changed here, because it would
            % influence spkBuffer
            if nargin<5,dispFrameNr=true;end
            if nargin<4,frameDur=obj.plotTimeBinSize;end
            if nargin<3,plotType=obj.plotType;end
            
            % load data and reshape for plotting if necessary
            obj.loadDataForPlotting(plotType, frameDur);
            
            if strcmpi(obj.plotType,'heatmap')
                maxD = max(obj.spkData(:));
                frame = obj.spkData(:,:,frameNr);
                imagesc(frame, [0 maxD])
                axis image square
                title(['Group ' obj.name ', rate = [0 , ' ...
                    num2str(maxD*1000/frameDur) ' Hz]'])
                xlabel('nrX')
                ylabel('nrY')
%                 set(gca, 'XTick', 0:obj.grid3D(2):obj.grid3D(2)*obj.grid3D(3))
                
                % if enabled, display the frame number in lower left corner
                if dispFrameNr
                    text(2,size(obj.spkData,1)-1,num2str(frameNr), ...
                        'FontSize',10,'BackgroundColor','white')
                end
            elseif strcmpi(obj.plotType,'raster')
                % find beginning and end of time bin to be displayed
                startTime = (frameNr-1)*frameDur;
                stopTime  = frameNr*frameDur;
                times = obj.spkData(1,:)>=startTime & obj.spkData(1,:)<stopTime;
                plot(obj.spkData(1,times),obj.spkData(2,times),'.k')
                axis([startTime stopTime 1 prod(obj.grid3D)])
                axis square
                title(['Group ' obj.name])
                xlabel('Time (ms)')
                ylabel('Neuron ID')
                set(gca, 'YTick', 0:round(prod(obj.grid3D)/10):prod(obj.grid3D))

                % if enabled, display the frame number in lower left corner
                if dispFrameNr
                    dX = startTime+(stopTime-startTime)*0.05;
                    dY = prod(obj.grid3D)*0.05;
                    text(dX, dY, num2str(frameNr), ...
                        'FontSize',10, 'BackgroundColor','white')
                end
            else
                obj.throwError(['Unrecognized plot type "' obj.plotType '".'])
                return
            end
        end
        
        function setGrid3D(obj, grid3D)
            % used to rearrange group layout
            if prod(grid3D) ~= prod(obj.grid3D)
                obj.throwError(['Population size cannot change when ' ...
                    'assigning new Grid3D property (old: ' ...
                    num2str(prod(obj.grid3D)) ', new: ' ...
                    num2str(prod(grid3D)) '.'])
            end
            
            obj.grid3D = grid3D;
        end
        
        function setPlotTimeBinSize(obj, binSize)
            if binSize<=0
                obj.throwError(['Bin size of plot time must be ' ...
                    'greater than zero.'])
            end
            obj.plotTimeBinSize = binSize;
        end
                
        function setPlotType(obj, plotType)
        % setPlotType(plotType) applies a certain plot type to the
            % group.
            % The default plot type is determined by the 3D dimensions of
            % the group (Grid3D property). A Nx1x1 layout will prefer a
            % raster plot, whereas an NxMx1 layout will prefer a 2D
            % heatmap.
            
            % find default plot type if necessary
            if strcmpi(plotType,'default')
                plotType = obj.getDefaultPlotType();
            end
            
            % make sure plot type is supported
            if ~obj.isPlotTypeSupported(plotType)
                obj.throwError(['plotType "' plotType '" is currently ' ...
                    'not supported. Choose from the following: ' ...
                    strjoin(obj.supportedPlotTypes, ', ') '.'])
            end
            
            % set plot type
            obj.plotType = plotType;
        end
        
        function setSpikeFileAttributes(obj,prefix,suffix)
            % obj.setSpikeFileAttributes(prefix,suffix)
            % Defines the naming conventions for spike files. They should
            % all reside within SAVEFOLDER (specified in constructor), and
            % be made of a common prefix, the population name (specified in
            % ADDPOPULATION), and a common suffix.
            % Example: files 'results/spkV1.dat', 'results/spkMT.dat'
            %   -> saveFolder = 'results/'
            %   -> prefix = 'spk'
            %   -> suffix = '.dat'
            %   -> name of population = 'V1' or 'MT'
            if nargin<3,suffix='.dat';end
            if nargin<2,prefix='spk';end
            
            obj.spkFilePrefix=prefix;
            obj.spkFileSuffix=suffix;
        end
    end
    
    %% PRIVATE METHODS
    methods (Hidden, Access = private)
        function initSpikeReader(obj)
            % private method to initialize SpikeReader
            spkFile = obj.getSpikeFileName();
            obj.spkObj = SpikeReader(spkFile, false, 'silent');
            
            % make sure spike file is valid
            [errFlag,errMsg] = obj.spkObj.getError();
            if errFlag
                obj.throwError(errMsg);
                return;
            end
            obj.grid3D = obj.spkObj.getGrid3D();
        end
        
        function isSupported = isErrorModeSupported(obj, errMode)
            % determines whether an error mode is currently supported
            isSupported = sum(ismember(obj.supportedErrorModes,errMode))>0;
        end
        
        function isSupported = isPlotTypeSupported(obj, plotType)
            % determines whether a plot type is currently supported
            isSupported = sum(ismember(obj.supportedPlotTypes,plotType))>0;
        end
        
        function loadDefaultParams(obj)
            obj.spkObj = [];
            obj.spkData = [];
            obj.spkFrameDur = -1;
            obj.setSpikeFileAttributes()
            
            obj.plotTimeBinSize = 1000;
            obj.plotType = 'default';
            obj.plotAbortPlotting = false;
            
            obj.grid3D = -1;
            obj.simLength = -1;
            
            obj.supportedPlotTypes  = {'heatmap', 'raster'};
            obj.supportedErrorModes = {'standard', 'warning', 'silent'};
        end
        
        function pauseOnKeyPressCallback(obj,~,eventData)
            % Callback function to pause plotting
            switch eventData.Key
                case 'p'
                    disp('Paused. Press any key to continue.');
                    waitforbuttonpress;
                case 'q'
                    obj.plotAbortPlotting = true;
            end
        end
        
        function throwError(obj, errorMsg, errorMode)
            % THROWERROR(errorMsg, errorMode) throws an error with a specific
            % severity (errorMode). In all cases, obj.errorFlag is set to true
            % and the error message is stored in obj.errorMsg. Depending on
            % errorMode, an error is either thrown as fatal, thrown as warning,
            % or not thrown at all.
            % If errorMode is not given, obj.errorMode is used.
            if nargin<3,errorMode=obj.errorMode;end
            obj.errorFlag = true;
            obj.errorMsg = errorMsg;
            if strcmpi(errorMode,'standard')
                error(errorMsg)
            elseif strcmpi(errorMode,'warning')
                warning(errorMsg)
            end
        end
        
        function unsetError(obj)
            % unsets error message and flag
            obj.errorFlag = false;
            obj.errorMsg = '';
        end
    end
end