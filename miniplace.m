function miniplace(varargin)
% CNN_IMAGENET   Demonstrates training a CNN on ImageNet
%   This demo demonstrates training the AlexNet, VGG-F, VGG-S, VGG-M,
%   VGG-VD-16, and VGG-VD-19 architectures on ImageNet data.

run(fullfile(fileparts(mfilename('fullpath')), ...
  '..','matconvnet-1.0-beta16', 'matlab', 'vl_setupnn.m')) ;

NUM_AUGMENTS = 1 ;
AUG_METHOD = 'f25' ; % 'stretch'
BATCH_SIZE = 256;
LOW_LR = false;


opts.dataDir = fullfile(fileparts(mfilename('fullpath')),'data') ;
opts.modelType = 'alexnet3' ;
opts.networkType = 'simplenn' ;
opts.batchNormalization = false ; %false
opts.weightInitMethod = 'gaussian';
%opts.weightInitMethod = 'xavierimproved' ;
[opts, varargin] = vl_argparse(opts, varargin) ;

sfx = opts.modelType ;
if opts.batchNormalization, sfx = [sfx '-bnorm'] ; end
if LOW_LR, sfx = [sfx '-lowlr'] ; end

opts.expDir = fullfile('data', sprintf('%s-%s-%d-aug%d-%s', ...
                       sfx, opts.weightInitMethod, BATCH_SIZE, NUM_AUGMENTS, AUG_METHOD)) ;
[opts, varargin] = vl_argparse(opts, varargin) ;

opts.numFetchThreads = 12 ; %12
opts.lite = false ;
opts.imdbPath = fullfile(opts.expDir, 'imdb.mat');
opts.train.batchSize = BATCH_SIZE ;%256
opts.train.numSubBatches = 1 ;
opts.train.continue = true ;
opts.train.gpus = [] ;
opts.train.prefetch = true ;
opts.train.sync = false ;
opts.train.cudnn = true ;
opts.train.expDir = opts.expDir ;
if ~opts.batchNormalization
    if LOW_LR
        opts.train.learningRate = logspace(-3, -4, 60) ; % -2 => -3
    else
        opts.train.learningRate = logspace(-2, -4, 60) ;
    end
else
  opts.train.learningRate = logspace(-1, -4, 20) ;
end
[opts, varargin] = vl_argparse(opts, varargin) ;

opts.train.numEpochs = numel(opts.train.learningRate) ;
opts = vl_argparse(opts, varargin) ;

% -------------------------------------------------------------------------
%                                                   Database initialization
% -------------------------------------------------------------------------

if exist(opts.imdbPath)
  imdb = load(opts.imdbPath) ;
else
  imdb = miniplace_setup_imdb() ;
  mkdir(opts.expDir) ;
  save(opts.imdbPath, '-struct', 'imdb') ;
end

% -------------------------------------------------------------------------
%                                                    Network initialization
% -------------------------------------------------------------------------

net = miniplace_init('model', opts.modelType, ...
                        'batchNormalization', opts.batchNormalization, ...
                        'weightInitMethod', opts.weightInitMethod) ;
bopts = net.normalization ;
bopts.numThreads = opts.numFetchThreads ;

% compute image statistics (mean, RGB covariances etc)
imageStatsPath = fullfile(opts.expDir, 'imageStats.mat') ;
if exist(imageStatsPath)
  load(imageStatsPath, 'averageImage', 'rgbMean', 'rgbCovariance') ;
else
  [averageImage, rgbMean, rgbCovariance] = getImageStats(imdb, bopts) ;
  save(imageStatsPath, 'averageImage', 'rgbMean', 'rgbCovariance') ;
end

% One can use the average RGB value, or use a different average for
% each pixel
%net.normalization.averageImage = averageImage ;
net.normalization.averageImage = rgbMean ;

switch lower(opts.networkType)
  case 'simplenn'
  case 'dagnn'
    net = dagnn.DagNN.fromSimpleNN(net, 'canonicalNames', true) ;
    net.addLayer('error', dagnn.Loss('loss', 'classerror'), ...
                 {'prediction','label'}, 'top1error') ;
  otherwise
    error('Unknown netowrk type ''%s''.', opts.networkType) ;
end

% -------------------------------------------------------------------------
%                                               Stochastic gradient descent
% -------------------------------------------------------------------------

[v,d] = eig(rgbCovariance) ;
bopts.transformation = AUG_METHOD ;
bopts.averageImage = rgbMean ;
bopts.rgbVariance = 0.1*sqrt(d)*v' ;

if NUM_AUGMENTS > 1
    bopts.numAugments = NUM_AUGMENTS;
    opts.train.numAugments = bopts.numAugments;
end

useGpu = numel(opts.train.gpus) > 0 ;

switch lower(opts.networkType)
  case 'simplenn'
    fn = getBatchSimpleNNWrapper(bopts) ;
    [net,info] = cnn_train(net, imdb, fn, opts.train, 'conserveMemory', true) ;
  case 'dagnn'
    fn = getBatchDagNNWrapper(bopts, useGpu) ;
    opts.train = rmfield(opts.train, {'sync', 'cudnn'}) ;
    info = cnn_train_dag(net, imdb, fn, opts.train) ;
end

% -------------------------------------------------------------------------
function fn = getBatchSimpleNNWrapper(opts)
% -------------------------------------------------------------------------
fn = @(imdb,batch) getBatchSimpleNN(imdb,batch,opts) ;

% -------------------------------------------------------------------------
function [im,labels] = getBatchSimpleNN(imdb, batch, opts)
% -------------------------------------------------------------------------
images = strcat([imdb.imageDir filesep], imdb.images.name(batch)) ;
im = miniplace_get_batch(images, opts, ...
                            'prefetch', nargout == 0) ;
if isfield(opts,'numAugments')
    labels = kron(imdb.images.label(batch), ones(1, opts.numAugments)) ;
else
    labels = imdb.images.label(batch);
end

% -------------------------------------------------------------------------
function fn = getBatchDagNNWrapper(opts, useGpu)
% -------------------------------------------------------------------------
fn = @(imdb,batch) getBatchDagNN(imdb,batch,opts,useGpu) ;

% -------------------------------------------------------------------------
function inputs = getBatchDagNN(imdb, batch, opts, useGpu)
% -------------------------------------------------------------------------
images = strcat([imdb.imageDir filesep], imdb.images.name(batch)) ;
im = miniplace_get_batch(images, opts, ...
                            'prefetch', nargout == 0) ;
if nargout > 0
  if useGpu
    im = gpuArray(im) ;
  end
  inputs = {'input', im, 'label', imdb.images.label(batch)} ;
end

% -------------------------------------------------------------------------
function [averageImage, rgbMean, rgbCovariance] = getImageStats(imdb, opts)
% -------------------------------------------------------------------------
train = find(imdb.images.set == 1) ;
train = train(1: 10: end); %train = train(1: 101: end);
bs = 256 ;
fn = getBatchSimpleNNWrapper(opts) ;
for t=1:bs:numel(train)
  batch_time = tic ;
  batch = train(t:min(t+bs-1, numel(train))) ;
  fprintf('collecting image stats: batch starting with image %d ...', batch(1)) ;
  temp = fn(imdb, batch) ;
  z = reshape(permute(temp,[3 1 2 4]),3,[]) ;
  n = size(z,2) ;
  avg{t} = mean(temp, 4) ;
  rgbm1{t} = sum(z,2)/n ;
  rgbm2{t} = z*z'/n ;
  batch_time = toc(batch_time) ;
  fprintf(' %.2f s (%.1f images/s)\n', batch_time, numel(batch)/ batch_time) ;
end
averageImage = mean(cat(4,avg{:}),4) ;
rgbm1 = mean(cat(2,rgbm1{:}),2) ;
rgbm2 = mean(cat(3,rgbm2{:}),3) ;
rgbMean = rgbm1 ;
rgbCovariance = rgbm2 - rgbm1*rgbm1' ;
