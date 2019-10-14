%  Open ELab in MANAGER mode
%  In this mode, you can LIST and INSTALL devices
%
%  Example: 
%           elab_manager = ELab();  % Creating elab instance by calling 
%                                   % ELab class without parameters, 
%                                   % automatically triggers the MANAGER mode.
%           elab_manager.list();    % Displays list of devices available in
%                                   % elab master database.
%           
%           elab_manager.install('pct23'); % Installs library files for
%                                           % the device 'pct23'.
%
%  Open ELab in CONTROL mode
%  In this mode, you have full control over selected device
%
%  Example: 
%           elab_manager = ELab(DEVICE_NAME, MODE, ADDRESS, LOGGING, LOGGING_PERIOD, INTERNAL_SAMPLING_PERIOD, POLLING_PERIOD); 
%
%           where DEVICE_NAME (String) is a designated name of the device (e.g. 'pct23'),
%                 MODE (String) is mode switch with possible values 'MANAGER', 'CONTROL', 'MONITOR',
%                 ADDRESS (String) is HTTP address of elab master SCADA system,
%                 LOGGING (0 or 1) is switch for online data logging into elab master database,
%                 LOGGING_PERIOD (N seconds) defines how often the measured data is logged into database,
%                 INTERNAL_SAMPLING_PERIOD (N seconds) defines how often the device streams new data to the elab SCADA master,
%                 POLLING_PERIOD (N seconds) defines how often the ELab class refreshes the data from SCADA master (this should be set to Ts)
%

classdef ELab < handle
    
    properties(SetAccess=public)
        Logging                     % logging trigger
        LoggingSessionKey
        PollingObj
        PollingPeriod
        LoggingPeriod
        TargetName                  % name of experiment
        VerboseMode
        TargetUpdateFreq
        Mode
        Data
        Tags
    end
    
    properties(Hidden)
        ElabServiceUrl = ''
        ApiRoutes = struct( ...
            'get_targets_json',   '/api/get/targets/json', ...
            'get_lib_file',       '/api/get/lib/:fname', ...
            'get_config_json',    '/api/get/:id/config/json', ...
            'get_data_json',      '/api/get/:id/data/json/all/:misc?', ...
            'get_data_json_raw',  '/api/get/:id/data/json/raw', ...
            'get_data_json_meas', '/api/get/:id/data/json/measurements/:misc?', ...
            'get_data_json_comm', '/api/get/:id/data/json/commands/:misc?', ...
            'set_command',        '/api/set/:id/command/:message/:log?/:session_key?/:stime?', ...
            'set_verbose',        '/api/set/:id/verbose/:state', ...
            'set_frequency',      '/api/set/:id/frequency/:freq', ...
            'set_data',           '/api/set/:id/data/:tag/:value/:frame_id?', ...
            'set_batch',          '/api/set/:id/batch/:values/:frame_id?', ...
            'set_defaults',       '/api/set/:id/defaults', ...
            'get_session',        '/api/get/session/:session_key', ...
            'get_sessions',       '/api/get/sessions/:lastn?', ...
            'get_session_data',   '/api/get/session/data/:session_key/:convert_units?', ...
            'get_session_qr',     '/api/get/session/qr/:session_key', ...
            'set_logging',        '/api/set/:id/logging/:db/:bc/:sg/:sampling_ms?' ...
            );
        FrameId = 0
    end
    
    methods(Access=public)
        
        function obj = ELab(varargin) % ELab constructor method
            
            % input validation
            validStr = @(x) ischar(x);
            validMode = @(MODE) ischar(MODE) && (strcmpi(MODE,'control') || strcmpi(MODE,'monitor') || strcmpi(MODE,'manager'));
            validBin = @(OPT) (OPT==1 || OPT==0) && isscalar(OPT);
            validPeriod = @(Ts) Ts>=0.05 && Ts<=10;
            defaultMode = 'control';
            defaultAddress = 'http://192.168.1.108:3030';
            defaultLogging = 0;
            defaultLoggingPeriod = 1;
            defaultInternalSamplingPeriod = 1;
            defaultPollingPeriod = 1;
            parser = inputParser;
            addOptional(parser,'target_name','',validStr);
            addOptional(parser,'mode',defaultMode,validMode);
            addOptional(parser,'address',defaultAddress,validStr);
            addOptional(parser,'logging',defaultLogging,validBin);
            addOptional(parser,'loggingPeriod',defaultLoggingPeriod,validPeriod);
            addOptional(parser,'internalSamplingPeriod',defaultInternalSamplingPeriod,validPeriod);
            addOptional(parser,'pollingPeriod',defaultPollingPeriod,validPeriod);
            parse(parser,varargin{:});
            param = parser.Results;
            
            % initialization of properties
            obj.ElabServiceUrl = param.address;
            obj.TargetName = param.target_name;
            if(isempty(obj.TargetName)|| strcmpi(param.mode,'manager'))
                obj.Mode = 'manager';
            else
                obj.Mode = param.mode;
            end
            obj.VerboseMode = 0;
            obj.PollingPeriod = param.pollingPeriod;
            obj.Logging = param.logging;
            obj.LoggingPeriod = param.loggingPeriod;
            
            % mode init
            if(strcmpi(obj.Mode,'control'))
                disp('Elab started in CONTROL mode. You have full control over the device.');
                obj.fetchApi('set_defaults', {':id', obj.TargetName});
                obj.setTargetStreamFreqency(ceil(1/param.internalSamplingPeriod));
                obj.setTargetStream(1);
                obj.initPollingObj();
                obj.setLoggingSession(param.logging);
            elseif(strcmpi(obj.Mode,'monitor'))
                disp('Elab started in MONITOR mode. You can observe measured data, but have no control over the device.');
                obj.setTargetStream(1);
            elseif(strcmpi(obj.Mode,'manager'))
                disp('Elab started in MANAGER mode. Control and measurement functions will not work.');
            end
        end
        
        function setVerboseMode(obj, mode)
            % ELab.setVerboseMode turns on/off debugging console log
            %
            % Usage:
            %       my_lab.setVerboseMode(1); % turns debugging on
            %       my_lab.setVerboseMode(0); % turns debugging off
            
            obj.VerboseMode = mode;
        end
        
        function tag = getTag(obj,name)
            tags = obj.getAllTags();
            tag = tags.(name);
        end
        
        function value = getTagValue(obj,name)
            tag = obj.getTag(name);
            value = tag.value;
        end
        
        function tags = getAllTags(obj)
            tags = obj.parseDataObj();
        end
        
        function list(obj)
            targets_list = obj.fetchApi('get_targets_json',{});
            obj.dispAsTable(targets_list);
        end
        
        function install(obj,target_name)
            targets_list = obj.fetchApi('get_targets_json',{});
            if (obj.isInTargetList(targets_list,target_name))
                obj.installTarget(target_name,targets_list);
            else
                warning('ELabWarning:TargetNotFound',['Entered device name ''' target_name ''' is not registered in ELab master database.']);
            end
        end
        
        function open(obj,target_name)
            targets_list = obj.fetchApi('get_targets_json',{});
            if (obj.isInTargetList(targets_list,target_name))
                current_dir = fileparts(which(mfilename));
                cmd_demo_dir = [current_dir filesep 'elab_targets' filesep target_name filesep 'examples' filesep 'cmd_example.m'];
                sim_demo_dir = [current_dir filesep 'elab_targets' filesep target_name filesep 'examples' filesep 'sim_example.m'];
                if strcmp(filesep, '\')
                    cmd_demo_dir = strrep(cmd_demo_dir,'\','\\');
                    sim_demo_dir = strrep(sim_demo_dir,'\','\\');
                end
                cmd_line_link = obj.getCommandLink('command line example', ['edit ' cmd_demo_dir]);
                sim_line_link = obj.getCommandLink('Simulink example', ['edit ' sim_demo_dir]);
                fprintf('Would you rather use command line or Simulink?\n');
                fprintf(['Click to open ' cmd_line_link '\n']);
                fprintf(['Click to open ' sim_line_link '\n']);
            else
                warning('ELabWarning:TargetNotFound',['Entered device name ''' target_name ''' is not registered in ELab master database.']);
            end
        end
        
        function confirm = setTag(obj,name,value)
            if(strcmpi(obj.Mode,'control'))
                obj.nextFrameId();
                confirm = obj.fetchApi('set_data',{':id', obj.TargetName, ':tag', name, ':value', value, ':frame_id?', obj.FrameId});
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
                confirm = 0;
            end
        end
        
        function confirm = setTags(obj,batch)
            if(strcmpi(obj.Mode,'control'))
                len = length(batch);
                param_string = '';
                for i = 1:2:len
                    param_string = [param_string batch{i} '=' num2str(batch{i+1})];
                    if(i~=len-1)
                        param_string = [param_string '&'];
                    end
                end
                obj.nextFrameId();
                confirm = obj.fetchApi('set_batch',{':id', obj.TargetName, ':values', param_string, ':frame_id?', obj.FrameId});
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
                confirm = 0;
            end
        end
        
        function elab_data_obj = getHistorianData(obj)
            elab_data_obj = ELabData(obj.LoggingSessionKey);
        end
        
        function setTargetStream(obj, opt)
            % Sets data stream from target node to master server (0 - off, 1 - on)
            if(opt==0 || opt==1)
                obj.fetchApi('set_verbose',{':id', obj.TargetName, ':state', opt});
            else
                warning('ELabWarning:WrongOption','Method accepts only values [0, 1].');
            end
        end
        
        function confirm = setTargetStreamFreqency(obj, freq)
            % Sets data stream frequency [in Hz] from target node to master
            % server.
            % Accepts only integers in range 1 to 50 Hz.
            if(strcmpi(obj.Mode,'control'))
                if(freq>=1 && freq<=50 && mod(freq,1)==0)
                    confirm = obj.fetchApi('set_frequency',{':id', obj.TargetName, ':freq', freq});
                    obj.TargetUpdateFreq = freq;
                else
                    warning('ELabWarning:WrongValue','Method accepts only integers in range 1 to 50 [Hz].');
                end
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
                confirm = 0;
            end
        end
        
        function setPollingPeriod(obj, per)
            if(strcmpi(obj.Mode,'control'))
                obj.PollingPeriod = per;
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
            end
        end
        
        function off(obj)
            % ELab.off resets the active set of experiment to its initial
            % values.
            if(strcmpi(obj.Mode,'control'))
                obj.fetchApi('set_defaults', {':id', obj.TargetName});
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
            end
        end
        
        function close(obj)
            % Closes active connection
            if(strcmpi(obj.Mode,'control'))
                obj.setTargetStream(0);
                obj.setTargetStreamFreqency(1);
                obj.off();
                obj.stop();
                delete(obj.PollingObj);
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
            end
        end
        
        function stop(obj)
            if(strcmpi(obj.Mode,'control'))
                obj.setLoggingSession(0);
                stop(obj.PollingObj);
                delete(obj.PollingObj);
            else
                warning('ELabWarning:WrongMode',['This action is forbidden in ' upper(obj.Mode) ' mode.']);
            end
        end
    end
    
    methods(Access=private)
        
        function dispAsTable(obj, targets_list)
            fprintf('-----------------------------------------------\n');
            fprintf('DEVICE');
            obj.fillSpace('DEVICE',16);
            fprintf('DESCRIPTION\n');
            fprintf('-----------------------------------------------\n');
            for i = 1:length(targets_list.targets)
                fprintf('%s',targets_list.targets(i).name);
                obj.fillSpace(targets_list.targets(i).name,16);
                fprintf('%s\n',targets_list.targets(i).description);
            end
            fprintf('-----------------------------------------------\n');
        end
        
        function output = fetchApi(obj, route, params)
            param_route = obj.fillParams(obj.ApiRoutes.(route), params);
            output = jsondecode(urlread([obj.ElabServiceUrl param_route]));
        end
        
        function output = getApiURL(obj, route, params)
            param_route = obj.fillParams(obj.ApiRoutes.(route), params);
            output = [obj.ElabServiceUrl param_route];
        end
        
        function setLoggingSession(obj, opt)
            if(opt==0 || opt==1)
                session = obj.fetchApi('set_logging',{':id',obj.TargetName,':db',opt,':bc',0,':sg',0,':sampling_ms?',round(obj.LoggingPeriod*1000)});
                if(opt==1 && length(session.session_key)==32)
                    obj.LoggingSessionKey = session.session_key;
                    session_path = [pwd filesep 'elab_sessions'];
                    [status, ~] = mkdir(session_path);
                    if(status)
                        fname = ['elab_session_' datestr(now,'YYYYmmdd_HHMMSS') '.m'];
                        filepath = [session_path filesep fname];
                        [fid,~] = fopen(filepath,'w');
                        fprintf(fid,'%% Session data measured on %s\n%%\n',datestr(now,'dd.mm.YYYY HH:MM:SS'));
                        fprintf(fid,'%% Device: %s\n\n',obj.TargetName);
                        fprintf(fid,'%% This key is used to access the data measured during the session.\n');
                        fprintf(fid,'session_key = ''%s'';\n\n',obj.LoggingSessionKey);
                        fprintf(fid,'%% Get your data. For more information, use ''help ELab''\n');
                        fprintf(fid,'elab_data = ELabData(session_key);\n');
                        fclose(fid);
                    end
                    fprintf(1,'Logging session was set successfully with key %s.\nYour session file is <a href="matlab:edit %s">%s</a>.\n',session.session_key,filepath,filepath);
                else
                    fprintf(1,'Logging session is not running.\n');
                end
            else
                warning('ELabWarning:WrongOption','Method accepts only values [0, 1].');
            end
        end
        
        function initPollingObj(obj)
            obj.PollingObj = timer();
            obj.PollingObj.ExecutionMode = 'fixedRate';
            obj.PollingObj.Period = obj.PollingPeriod;
            obj.PollingObj.TimerFcn = @(~,evt)obj.updatePollingFcn();
            start(obj.PollingObj);
        end
        
        function updatePollingFcn(obj)
            data = obj.fetchApi('get_data_json',{':id', obj.TargetName, ':misc?', 3});
            obj.Data = data;
            obj.Tags = obj.getAllTags();
        end
        
        function output = parseDataObj(obj)
            output = struct;
            fields = fieldnames(obj.Data);
            for i = 1:length(fields)-2
                tags = fieldnames(obj.Data.(fields{i}));
                for j = 1:length(tags)
                    output.(tags{j}) = obj.Data.(fields{i}).(tags{j});
                end
            end
        end
        
        function installTarget(obj,target_name,targets_list)
            current_dir = fileparts(which(mfilename));
            file_name = '';
            for i = 1:length(targets_list.targets)
                if(strcmp(targets_list.targets(i).name,target_name))
                    file_name = targets_list.targets(i).lib_files;
                end
            end
            target_url = obj.getApiURL('get_lib_file',{':fname',file_name});
            [temp_path,status] = urlwrite(target_url,[current_dir filesep 'temp_target.zip']);
            if(~status)
                warning('ELabWarning:DownloadFailure','Target ''%s'' could not be downloaded from repository.',target_name);
                success = 0;
                return
            end
            unzip(temp_path,[current_dir filesep 'elab_targets' filesep target_name filesep]);
            delete(temp_path);
            if(exist([current_dir filesep 'elab_targets' filesep target_name],'dir') == 7)
                success = 1;
                fprintf('Add target''s directory to permanent path?\n');
                fprintf('%s \n',[current_dir filesep 'elab_targets' filesep target_name]);
                fprintf('If ''NO'' option is selected, it will be added to temporary path.\n[y,n]?\n');
                c = input('','s');
                if(strcmpi(c,'y'))
                    obj.add2path([filesep 'elab_targets' filesep target_name],1);
                    fprintf('%s \n',[current_dir filesep 'elab_targets' filesep target_name]);
                    fprintf('Added to permanent path.\n')
                else
                    obj.add2path([filesep 'elab_targets' filesep target_name],0);
                    fprintf('%s \n',[current_dir filesep 'elab_targets' filesep target_name]);
                    fprintf('Added to temporary path.\n')
                end
            else
                success = 0;
                warning('ELabManagerWarning:UnzipFailure','An error occured during extraction of archive %s.',temp_path);
            end
        end
        
        function nextFrameId(obj)
            obj.FrameId = obj.FrameId + 1;
            if(obj.FrameId>255)
                obj.FrameId = 0;
            end
        end
        
    end
    
    methods(Static)
        
        function printCommandLink(link_text, commands)
            fprintf('<a href="matlab:%s">%s</a>',commands,link_text);
        end
        
        function out = getCommandLink(link_text, commands)
            out = sprintf('<a href="matlab:%s">%s</a>',commands,link_text);
        end
        
        function is = isInTargetList(list, name)
            is = 0;
            for i=1:length(list.targets)
                is = is | strcmp(list.targets(i).name, name);
            end
        end
        
        function fillSpace(str,len)
            str_len = length(str);
            for x = 1:(len-str_len)
                fprintf(' ');
            end
        end
        
        function output = fillParams(param_route, params)
            for i = 1:2:length(params)
                param_route = strrep(param_route,params{i},num2str(params{i+1}));
            end
            output = param_route;
        end
        
        function add2path(subdir,perm)
            current_dir = fileparts(which(mfilename));
            addpath(genpath([current_dir filesep subdir]));
            if(perm)
                savepath;
            end
        end
        
    end
    
end