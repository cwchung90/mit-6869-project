function [net, info] = cnn_train_multilabels(net, imdb, getBatch, varargin)

opts.batchSize = 256;
opts.numSubBatches = 1;
opts.train = [];
opts.val = [];
opts.numEpochs = 300;
opts.gpus = [];
opts.learningRate = 0.0001;
opts.continue = false;
opts.expDir = fullfile('data','exp');
opts.conserveMemory = false;
opts.backPropDepth = +inf;
opts.sync = false;
opts.prefetch = false;
opts.cudnn = true;
opts.weightDecay = 0.0005;
opts.momentum = 0.9;
opts.errorLabels = {};
opts.plotDiagnostics = false;
opts.memoryMapFile = fullfile(tempdir, 'matconvnet.bin');
opts.numAugments = 1;
opts = vl_argparse(opts, varargin);

if ~exist(opts.expDir, 'dir'), mkdir(opts.expDir); end
if isempty(opts.train), opts.train = find(imdb.images.set==1); end
if isempty(opts.val), opts.val = find(imdb.images.set==2); end
if isnan(opts.train), opts.train = []; end

% -------------------------------------------------------------------------
%                                                    Network initialization
% -------------------------------------------------------------------------

evaluateMode = isempty(opts.train);

if ~evaluateMode
  for i=1:numel(net.layers)
    if isfield(net.layers{i}, 'weights')
      J = numel(net.layers{i}.weights);
      for j=1:J
        net.layers{i}.momentum{j} = zeros(size(net.layers{i}.weights{j}), 'single');
      end
      if ~isfield(net.layers{i}, 'learningRate')
        net.layers{i}.learningRate = ones(1, J, 'single');
      end
      if ~isfield(net.layers{i}, 'weightDecay')
        net.layers{i}.weightDecay = ones(1, J, 'single');
      end
    end
  end
end

% setup GPUs
numGpus = numel(opts.gpus);
if numGpus > 1
  if isempty(gcp('nocreate')),
    parpool('local',numGpus);
    spmd, gpuDevice(opts.gpus(labindex)), end
  end
elseif numGpus == 1
  gpuDevice(opts.gpus)
end
if exist(opts.memoryMapFile), delete(opts.memoryMapFile); end

if isempty(opts.errorLabels)
  opts.errorLabels = {'error'};
end

% -------------------------------------------------------------------------
%                                                        Train and validate
% -------------------------------------------------------------------------

modelPath = @(ep) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', ep));
modelFigPath = fullfile(opts.expDir, 'net-train.pdf');

start = opts.continue * findLastCheckpoint(opts.expDir);
if start >= 1
  fprintf('resuming by loading epoch %d\n', start);
  load(modelPath(start), 'net', 'info');
end

for epoch=start+1:opts.numEpochs

  % train one epoch and validate
  learningRate = opts.learningRate(min(epoch, numel(opts.learningRate)));
  train = opts.train(randperm(numel(opts.train))); % shuffle
  val = opts.val;
  if numGpus <= 1
    [net,stats.train] = process_epoch(opts, getBatch, epoch, train, learningRate, imdb, net);
    [~,stats.val] = process_epoch(opts, getBatch, epoch, val, 0, imdb, net);
  else
    spmd(numGpus)
      [net_, stats_train_] = process_epoch(opts, getBatch, epoch, train, learningRate, imdb, net);
      [~, stats_val_] = process_epoch(opts, getBatch, epoch, val, 0, imdb, net_);
    end
    net = net_{1};
    stats.train = sum([stats_train_{:}],2);
    stats.val = sum([stats_val_{:}],2);
  end

  % save
  if evaluateMode, sets = {'val'}; else sets = {'train', 'val'}; end
  for f = sets
    f = char(f);
    n = numel(eval(f));

    if isfield(opts,'numAugments')
        n = n * opts.numAugments;
    end
    
    info.(f).speed(epoch) = n / stats.(f)(1) * max(1, numGpus);
    info.(f).objective(epoch) = stats.(f)(2) / n;
    info.(f).error(:,epoch) = stats.(f)(3:end) / n;
  end
  if ~evaluateMode, save(modelPath(epoch), 'net', 'info'); end

  figure(1); clf;
  hasError = true;
  subplot(1,1+hasError,1);
  if ~evaluateMode
    semilogy(1:epoch, info.train.objective, '.-', 'linewidth', 2);
    hold on;
  end
  semilogy(1:epoch, info.val.objective, '.--');
  xlabel('training epoch'); ylabel('energy');
  grid on;
  h=legend(sets);
  set(h,'color','none');
  title('objective');
  if hasError
    subplot(1,2,2); leg = {};
    if ~evaluateMode
      plot(1:epoch, info.train.error', '.-', 'linewidth', 2);
      hold on;
      leg = horzcat(leg, strcat('train ', opts.errorLabels));
    end
    plot(1:epoch, info.val.error', '.--');
    leg = horzcat(leg, strcat('val ', opts.errorLabels));
    set(legend(leg{:}),'color','none');
    grid on;
    xlabel('training epoch'); ylabel('error');
    title('error');
  end
  drawnow;
  print(1, modelFigPath, '-dpdf');
end

% -------------------------------------------------------------------------
function err = error_multiclass(opts, labels, res)
% -------------------------------------------------------------------------
predictions = gather(res(end-1).x);

if ~isempty(predictions)
  pred_re = reshape(predictions, size(labels, 1), size(labels, 2));
  err = sum(sum((pred_re - labels) .^ 2));
else
  err = gather(res(end).x);
end

% -------------------------------------------------------------------------
function  [net_cpu,stats,prof] = process_epoch(opts, getBatch, epoch, subset, learningRate, imdb, net_cpu)
% -------------------------------------------------------------------------

% move CNN to GPU as needed
numGpus = numel(opts.gpus);
if numGpus >= 1
  net = vl_simplenn_move(net_cpu, 'gpu');
else
  net = net_cpu;
  net_cpu = [];
end

% validation mode if learning rate is zero
training = learningRate > 0;
if training, mode = 'training'; else, mode = 'validation'; end
if nargout > 2, mpiprofile on; end

numGpus = numel(opts.gpus);
if numGpus >= 1
  one = gpuArray(single(1));
else
  one = single(1);
end
res = [];
mmap = [];
stats = [];
start = tic;

for t=1:opts.batchSize:numel(subset)
  fprintf('%s: epoch %02d: batch %3d/%3d: ', mode, epoch, ...
          fix(t/opts.batchSize)+1, ceil(numel(subset)/opts.batchSize));
  batchSize = min(opts.batchSize, numel(subset) - t + 1);
  numDone = 0;
  error = [];
  for s=1:opts.numSubBatches
    % get this image batch and prefetch the next
    batchStart = t + (labindex-1) + (s-1) * numlabs;
    batchEnd = min(t+opts.batchSize-1, numel(subset));
    batch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd);
    [im, labels] = getBatch(imdb, batch);

    if opts.prefetch
      if s==opts.numSubBatches
        batchStart = t + (labindex-1) + opts.batchSize;
        batchEnd = min(t+2*opts.batchSize-1, numel(subset));
      else
        batchStart = batchStart + numlabs;
      end
      nextBatch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd);
      getBatch(imdb, nextBatch);
    end

    if numGpus >= 1
      im = gpuArray(im);
    end

    % evaluate CNN
    net.layers{end}.class = labels;
    if training, dzdy = one; else, dzdy = []; end
    res = vl_simplenn(net, im, dzdy, res, ...
                      'accumulate', s ~= 1, ...
                      'disableDropout', ~training, ...
                      'conserveMemory', opts.conserveMemory, ...
                      'backPropDepth', opts.backPropDepth, ...
                      'sync', opts.sync, ...
                      'cudnn', opts.cudnn);

    % accumulate training errors
    error = sum([error, [...
      sum(sum(double(gather(res(end-1).x))));
      reshape(error_multiclass(opts, labels, res),[],1); ]],2);
    numDone = numDone + numel(batch);
  end

  % gather and accumulate gradients across labs
  if training
    if numGpus <= 1
      [net,res] = accumulate_gradients(opts, learningRate, batchSize, net, res);
    else
      if isempty(mmap)
        mmap = map_gradients(opts.memoryMapFile, net, res, numGpus);
      end
      write_gradients(mmap, net, res);
      labBarrier();
      [net,res] = accumulate_gradients(opts, learningRate, batchSize, net, res, mmap);
    end
  end

  % print learning statistics

  time = toc(start);
  stats = sum([stats,[0; error]],2); % works even when stats=[]
  stats(1) = time;
  n = (t + batchSize - 1) / max(1,numlabs);

  if isfield(opts,'numAugments')
      n = n * opts.numAugments;
  end
 
  speed = n/time;
  fprintf('%.1f Hz%s\n', speed);

  fprintf(' sum_predicted:%.3g', stats(2)/n);
  for i=1:numel(opts.errorLabels)
    % sqrt applied since the error is calculated by 2-norm.
    fprintf(' %s:%.3g', opts.errorLabels{i}, sqrt(stats(i+2)/n));
  end
  fprintf(' [%d/%d]', numDone, batchSize);
  fprintf('\n');
end

if nargout > 2
  prof = mpiprofile('info');
  mpiprofile off;
end

if numGpus >= 1
  net_cpu = vl_simplenn_move(net, 'cpu');
else
  net_cpu = net;
end

% -------------------------------------------------------------------------
function [net,res] = accumulate_gradients(opts, lr, batchSize, net, res, mmap)
% -------------------------------------------------------------------------
for l=numel(net.layers):-1:1
  for j=1:numel(res(l).dzdw)
    thisDecay = opts.weightDecay * net.layers{l}.weightDecay(j);
    thisLR = lr * net.layers{l}.learningRate(j);

    % accumualte from multiple labs (GPUs) if needed
    if nargin >= 6
      tag = sprintf('l%d_%d',l,j);
      tmp = zeros(size(mmap.Data(labindex).(tag)), 'single');
      for g = setdiff(1:numel(mmap.Data), labindex)
        tmp = tmp + mmap.Data(g).(tag);
      end
      res(l).dzdw{j} = res(l).dzdw{j} + tmp;
    end

    if isfield(net.layers{l}, 'weights')
      net.layers{l}.momentum{j} = ...
        opts.momentum * net.layers{l}.momentum{j} ...
        - thisDecay * net.layers{l}.weights{j} ...
        - (1 / batchSize) * res(l).dzdw{j};
      net.layers{l}.weights{j} = net.layers{l}.weights{j} + thisLR * net.layers{l}.momentum{j};
    else
      % Legacy code: to be removed
      if j == 1
        net.layers{l}.momentum{j} = ...
          opts.momentum * net.layers{l}.momentum{j} ...
          - thisDecay * net.layers{l}.filters ...
          - (1 / batchSize) * res(l).dzdw{j};
        net.layers{l}.filters = net.layers{l}.filters + thisLR * net.layers{l}.momentum{j};
      else
        net.layers{l}.momentum{j} = ...
          opts.momentum * net.layers{l}.momentum{j} ...
          - thisDecay * net.layers{l}.biases ...
          - (1 / batchSize) * res(l).dzdw{j};
        net.layers{l}.biases = net.layers{l}.biases + thisLR * net.layers{l}.momentum{j};
      end
    end
  end
end

% -------------------------------------------------------------------------
function mmap = map_gradients(fname, net, res, numGpus)
% -------------------------------------------------------------------------
format = {};
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    format(end+1,1:3) = {'single', size(res(i).dzdw{j}), sprintf('l%d_%d',i,j)};
  end
end
format(end+1,1:3) = {'double', [3 1], 'errors'};
if ~exist(fname) && (labindex == 1)
  f = fopen(fname,'wb');
  for g=1:numGpus
    for i=1:size(format,1)
      fwrite(f,zeros(format{i,2},format{i,1}),format{i,1});
    end
  end
  fclose(f);
end
labBarrier();
mmap = memmapfile(fname, 'Format', format, 'Repeat', numGpus, 'Writable', true);

% -------------------------------------------------------------------------
function write_gradients(mmap, net, res)
% -------------------------------------------------------------------------
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    mmap.Data(labindex).(sprintf('l%d_%d',i,j)) = gather(res(i).dzdw{j});
  end
end

% -------------------------------------------------------------------------
function epoch = findLastCheckpoint(modelDir)
% -------------------------------------------------------------------------
list = dir(fullfile(modelDir, 'net-epoch-*.mat'));
tokens = regexp({list.name}, 'net-epoch-([\d]+).mat', 'tokens');
epoch = cellfun(@(x) sscanf(x{1}{1}, '%d'), tokens);
epoch = max([epoch 0]);
