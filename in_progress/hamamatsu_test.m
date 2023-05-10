% NOTE ON INSTALLING SOFTWARE: 
% install these: https://dcam-api.com/hamamatsu-software/
% in matlab: imaqregister('C:\Users\peterslab\AppData\Roaming\MathWorks\MATLAB Add-Ons\Toolboxes\Hamamatsu Image Acquisition\hamamatsu.dll')

function hamamatsu_test

% Connect and set up camera
% NOTE: bit depth, binning, and speed mode, set by format
% To see list of formats:
% imaqhwinfo('hamamatsu').DeviceInfo.SupportedFormats';

cam_DeviceName = imaqhwinfo('hamamatsu').DeviceInfo.DeviceName;
video_object = videoinput('hamamatsu',cam_DeviceName,'MONO16_BIN2x2_1024x1024_FastMode');
% video_object = videoinput('hamamatsu',cam_DeviceName,'MONO12_BIN2x2_1024x1024_FastMode');
src = getselectedsource(video_object);

% video_object.LoggingMode = "disk";

% Set input trigger
src.TriggerSource = "external";
src.TriggerActive = "level";
src.TriggerGlobalExposure = "globalreset";

% Set outputs
src.OutputTriggerKindOpt1 = "triggerready";
src.OutputTriggerKindOpt2 = "exposure";

%% Set up GUI

gui_fig = figure('MenuBar','none','Units','Normalized', ...
    'Position',[0.01,0.2,0.32,0.5],'color','w','Colormap',gray);

% Preview image (2 images side-by-side: [color 1, color 2])
im_axes = axes(gui_fig,'Position',[0,0.05,1,0.8]);
im_preview = imagesc(zeros(1));

embedded_info_text = uicontrol('Style','text','String','Embedded header information', ...
    'Units','normalized','Position',[0,0,1,0.05], ...
    'BackgroundColor','w','HorizontalAlignment','left','FontSize',12, ...
    'FontName','Consolas');

% setappdata(im_preview,'UpdatePreviewWindowFcn',@preview_cam);
setappdata(im_preview,'gui_fig',gui_fig);

% preview(video_object,im_preview);
axis(im_axes);axis tight equal

% Status text
status_text_h = uicontrol('Parent',gui_fig,'Style','text', ...
    'FontSize',12,'FontName','Courier','HorizontalAlignment','left', ...
    'Units','normalized','BackgroundColor','w','Position',[0,0.9,1,0.1]);

% Control buttons
button_fontsize = 12;
view_button_position = [0,0.85,0.3,0.1];
clear controls_h
controls_h(1) = uicontrol('Parent',gui_fig,'Style','pushbutton','FontSize',button_fontsize, ...
    'Units','normalized','Position',view_button_position,'BackgroundColor','w', ...
    'String','Set ROI','Callback',{@set_roi,gui_fig});
controls_h(end+1) = uicontrol('Parent',gui_fig,'Style','togglebutton','FontSize',button_fontsize, ...
    'Units','normalized','Position',view_button_position,'BackgroundColor','w', ...
    'String','Manual','Callback',{@cam_manual,gui_fig});
align(controls_h,'fixed',20,'middle');

% Start listener for experiment controller
update_status_text(status_text_h,'Connecting to experiment server');
try
    client_expcontroller = tcpclient("163.1.249.17",plab.locations.mousecam_port,'ConnectTimeout',2);
    configureCallback(client_expcontroller, "terminator", ...
        @(src,event,x) read_expcontroller_data(src,event,gui_fig));
    update_status_text(status_text_h,'Listening for start');
catch me
    % Error if no connection to experiment controller
    update_status_text(status_text_h,'Error connecting to experiment server');
    warning(me.identifier,'Widefield -- Cannot connect to experiment controller: \n %s',me.message)
end

% Store gui data
gui_data.video_object = video_object;
gui_data.gui_fig = gui_fig;
gui_data.im_axes = im_axes;
gui_data.im_preview = im_preview;
gui_data.embedded_info_text = embedded_info_text;
gui_data.status_text_h = status_text_h;
gui_data.controls_h = controls_h;
if exist('client_expcontroller','var')
    gui_data.client_expcontroller = client_expcontroller;
end
% (initialize 2-color preview)
gui_data.im_preview_curr_color = 1; % (initialize)
gui_data.im_preview_color = ...
    repmat({zeros(fliplr(video_object.VideoResolution),'uint16')},1,2);

% Update GUI data
guidata(gui_fig,gui_data);

%%%%%% TESTING
video_object.FramesAcquiredFcn = {@preview_cam,gui_fig};
video_object.FramesAcquiredFcnCount = 8;
video_object.FramesPerTrigger = Inf;
start(video_object);

end

%% Button functions

function set_roi(h,eventdata,gui_fig)
% Draw and set ROI

% Get GUI data
gui_data = guidata(gui_fig);

% Reset ROI
gui_data.video_object.roi = [0,0,gui_data.video_object.VideoResolution];
axes(gui_data.im_axes); axis tight;

% Draw new ROI and want until finished
roi = drawrectangle(gui_data.im_axes);
wait(roi);

% Set new ROI position
roi_position = roi.Position;
if any(roi_position(2:3) == 0)
    roi_position = [0,0,gui_data.video_object.VideoResolution];
end
delete(roi);

stop(gui_data.video_object);
gui_data.video_object.roi = roi_position;
start(gui_data.video_object);

% Set tight axes
axes(gui_data.im_axes); axis tight;

% Update GUI data
guidata(gui_fig,gui_data);

end

function cam_manual(h,eventdata,gui_fig)

switch h.Value
    case 1
        % Manual recording is turned on

        % Get gui data
        gui_data = guidata(gui_fig);

        % Change button display and disable other buttons
        h.String = 'Stop';
        h.BackgroundColor = [0.8,0,0];
        h.ForegroundColor = 'w';
        set(gui_data.controls_h(gui_data.controls_h ~= h),'Enable','off');

        % User choose mouse name
        animal = cell2mat(inputdlg('Mouse name'));
        if isempty(animal)
            % (if no mouse entered, do nothing)
            return
        end

        % Set save filename
        save_dir = plab.locations.local_data_path;
        rec_day = datestr(now,'YYYY-mm-DD');
        rec_time = datestr(now,'HHMM');
        save_path = plab.locations.make_local_filename( ...
            animal,rec_day,rec_time,'mousecam');

        % Make local data directory
        mkdir(save_path);

        % Update gui data
        guidata(gui_fig,gui_data);

        % Start DAQ acquisition
        cam_start(gui_fig,save_path);

    case 0
        % Manual recording is turned off

        % Stop recording
        cam_stop(gui_fig)

        % Get gui data
        gui_data = guidata(gui_fig);

        % Change button display and disable other buttons
        h.String = 'Manual';
        h.BackgroundColor = 'w';
        h.ForegroundColor = 'k';
        set(gui_data.controls_h,'Enable','on');

end

end

function cam_start(gui_fig,save_path)
% Start recording

% Get GUI data
gui_data = guidata(gui_fig);

% Create videowriter
vidWriter = VideoWriter(fullfile(save_path,'mousecam.mj2'), 'Motion JPEG 2000');
vidWriter.CompressionRatio = 10;
gui_data.video_object.DiskLogger = vidWriter;

header_fn = fullfile(save_path,'mousecam_header.bin');
gui_data.header_fileID = fopen(header_fn,'w');

% Set header reader function
gui_data.video_object.FramesAcquiredFcnCount = 1;
gui_data.video_object.FramesAcquiredFcn = {@record_cam_header,gui_data.header_fileID};

% Start recording
start(gui_data.video_object);

% Reset relative display info
gui_data.set_relative_info_flag = true;

% Update status text
update_status_text(gui_data.status_text_h,'RECORDING');

% Update GUI data
guidata(gui_fig,gui_data);

end

function cam_stop(gui_fig)
% Stop recording

% Get GUI data
gui_data = guidata(gui_fig);

% Update status text
update_status_text(gui_data.status_text_h,'Stopping recording');

% Stop recording and close header file
pause(1); % pause to allow flipper to stop
stop(gui_data.video_object)
fclose(gui_data.header_fileID);

% Move data to server
curr_data_path = get(gui_data.video_object.DiskLogger,'path');
move_data_to_server(curr_data_path,gui_data.status_text_h);

% Update status text
update_status_text(gui_data.status_text_h,'Listening for start');

end

%% Preview/record functions

function preview_cam(h,eventdata,gui_fig)
% Custom preview function: output header information

% % Get GUI fig (grab different - can't input to this function)
% gui_fig = getappdata(himage,'gui_fig');

% Get GUI data
gui_data = guidata(gui_fig);

data = peekdata(gui_data.video_object,2);
if size(data,4) ~= 2
    return
end
set(gui_data.im_preview,'CData',reshape(data,size(data,1),[]))

% % Update appropriate color preview
% % gui_data.im_preview_color{gui_data.im_preview_curr_color} = ...
% %     eventdata.Data;
% gui_data.im_preview_color{1} = ...
%     eventdata.Data;
% if gui_data.im_preview_curr_color == 1
% % Update preview
% im_preview_sizes = cell2mat(reshape(cellfun(@size, ...
%     gui_data.im_preview_color,'uni',false),[],1));
% if all(all(im_preview_sizes == im_preview_sizes(1,:)))
%     % (if image sizes are the same, concatenate)
%     himage.CData = horzcat(gui_data.im_preview_color{:});
% else
%     % (otherwise: just show the current image)
%     himage.CData = gui_data.im_preview_color{gui_data.im_preview_curr_color};
% end
% end
% 
% % Queue next color
% gui_data.im_preview_curr_color = ...
%     1 + mod(gui_data.im_preview_curr_color,length(gui_data.im_preview_color));

% Update GUI data
guidata(gui_fig,gui_data);

end


function record_cam_header(video_object,vid_info,header_fileID)
% Pull headers from memory frames and save

if video_object.FramesAvailable > 0

    % Set embedded pixel index
    embedded_pixels_idx = 1:40; % 4 px * 10 items = 40 pixels

    % Grab all frames currently in memory
    curr_im = getdata(video_object, video_object.FramesAvailable);

    % Save raw embedded pixel values in bin file
    embedded_pixels = permute(curr_im(1,embedded_pixels_idx,1,:),[2,4,1,3]);
    fwrite(header_fileID,embedded_pixels);

end

end

function update_status_text(status_text_h,status)
% Update status text

curr_text = get(status_text_h,'String');
new_text = [{sprintf('Status: %s',status)};curr_text(2:end)];
set(status_text_h,'String',new_text);

end

%% Cross-computer functions

function read_expcontroller_data(client,event,gui_fig)
% Read message from experiment controller

% Get gui data
gui_data = guidata(gui_fig);

% Get message from experiment controller
expcontroller_message = readline(client);

if strcmp(expcontroller_message, 'stop')
    % If experiment controller sends stop, stop DAQ acquisition
    cam_stop(gui_fig);
else
    % If experiment controller send experiment info
    
    rec_info = jsondecode(expcontroller_message);

    % Set local filename
    save_path = ...
        plab.locations.make_local_filename( ...
        rec_info.mouse,rec_info.date,rec_info.time,'mousecam');

    % Make local save directory
    mkdir(save_path)
    
    % Start camera recording acquisition
    cam_start(gui_fig,save_path)
end

end

function move_data_to_server(curr_data_path,status_text_h)
% Move data from local to server

% Check if the server is available
if ~exist(plab.locations.server_data_path,'dir')
    warning('Server not accessible at %s',plab.locations.server_data_path)
    return
end

% Move local data directories to server
curr_data_path_server = strrep(curr_data_path, ...
    plab.locations.local_data_path,plab.locations.server_data_path);
update_status_text(status_text_h,'Copying to server')
[status,message] = movefile(curr_data_path,curr_data_path_server);
if ~status
    update_status_text(status_text_h,'Last server copy failed! Listening for start');
    warning('Failed copying to server: %s',message);
else
    update_status_text(status_text_h,'Listening for start');
end

% Delete empty local folders
% (3 hierarchy levels: protocol > day > animal)
try
    curr_hierarchy_path = fileparts(curr_data_path);
    for hierarchy_levels = 1:3
        hierarchy_dir = dir(curr_hierarchy_path);
        if all(contains({hierarchy_dir.name},'.'))
            rmdir(curr_hierarchy_path)
            % Move up one step in hierarchy
            curr_hierarchy_path = fileparts(curr_hierarchy_path);
        end
    end
end

end




