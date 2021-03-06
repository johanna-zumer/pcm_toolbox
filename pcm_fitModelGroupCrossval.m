function [T,theta_hat,G_pred]=pcm_fitModelGroupCrossval(Y,M,partitionVec,conditionVec,varargin);
% function [T,theta_hat,G_pred]=pcm_fitModelGroupCrossval(Y,M,partitionVec,conditionVec,varargin);
% Fits pattern component model(s) specified by M to data from a number of
% subjects.
% The model parameters are shared - the noise parameters are not.
% If provided with a G_hat and Sig_hat, it also automatically estimates close
% startingvalues.
%==========================================================================
% INPUT:
%        Y: {#Subjects}.[#Conditions x #Voxels]
%            Observed/estimated beta regressors from each subject.
%            Preferably multivariate noise-normalized beta regressors.
%
%        M: {#Model}
%           Cell array of models to be fitted for each subject.
%           Multiple competing models are stored in a cell array 
%           (e.g., M{3} means the third model).
% 
%           Requiered fields of each model structure are;
%              .type:        Type of the model to be fitted
%                             'fixed': Fixed structure without parameter
%                                (except scale and noise for each subject)
%                             'component': G is a sum of linear components,
%                                specified by Gc
%                             'feature': G=A*A', with A a linear sum of
%                                 weighted components Ac
%                             'nonlinear': Nonlinear model with own function
%                                 to return G-matrix and derivatives
%                             'freedirect': Uses the mean estimated
%                                 G-matrix from crossvalidation to get an
%                                 estimate of the best achievable fit
%              .numGparams:  Scalar that defines the number of parameters
%                             included in model.
%              .theta0:      Vector of starting values for theta. If not given,
%                              the function attempts to estimate these from a
%                              crossvalidated version Values usually estimated from
%                             observed second-moment matrix. 
%           Model-specific field 
%              .modelpred':  Modelling func. Must take theta values as vector
%                             and return predicated second moment matrix and
%                             derivatives in respect to parameters (for nonlinear models).
%              .Gc:          Linear component matrices (for type 'component')
%              .Ac           Linear component matrices (for type 'feature')
%
%   partitionVec: {#Subjects} Cell array with partition assignment vector
%                   for each subject. Rows of partitionVec{subj} define
%                   partition assignment of rows of Y{subj}.
%                   Commonly these are the scanning run #s for beta
%                   regressors.If 1 vector is given, then partitions are
%                   assumed to be the same across subjects.
%
%   conditionVec: {#Subjects} Cell array with condition assignment vector
%                   for each subject. Rows of conditionVec{subj} define
%                   condition assignment of rows of Y{subj}.
%                   If the (elements of) conditionVec are matrices, it is
%                   assumed to be the design matrix Z, allowing the
%                   specification individualized models. 
%--------------------------------------------------------------------------
% OPTION:
%   'runEffect': How to deal with effects that may be specific to different
%                imaging runs:
%                  'random': Models variance of the run effect for each subject
%                            as a seperate random effects parameter.
%                  'fixed': Consider run effect a fixed effect, will be removed
%                            implicitly using ReML.
%   'fitScale'      Introduce additional scaling parameter for each
%                   participant? - default is true
%   'isCheckDeriv:  Check the derivative accuracy of theta params. Done using
%                   'pcm_checkderiv'. This function compares input to finite
%                   differences approximations. See function documentation.
%
%   'MaxIteration': Number of max minimization iterations. Default is 1000.
%
%   'verbose':      Optional flag to show display message in the command
%                   line (e.g., elapsed time). Default is 1.
% 
%   'groupFit',theta:Parameters theta from the group fit: This provides better starting
%                    values and can speed up the computation. 
% 
%   'S':            Specific assumed noise structure - usually inv(XX'*XX),
%                   where XX is the first-level design matrix used to
%                   estimate the activation estimates 
%                   
%--------------------------------------------------------------------------
% OUTPUT:
%   T:      Structure with following subfields:
%       SN:                 Subject number
%       likelihood:         Crossvalidated likelihood
%       scale:              Fitted scaling parameter - exp(theta_scale)
%       noise:             	Fitted noise parameter - exp(theta_noise)
%       run:               	Fitted run parameter - exp(theta_run)
%
%   theta_hat{model}:   Cell array of models parameters from crossvalidation 
%                       theta: numGparams{m}xnumSubj Matrix: Estimated parameters 
%                       across the crossvalidation rounds from the training set.
%   Gpred{model}(:,:,subject): Predicted second moment matrix for each model
%                              from cross-validation fit. 3rd dimension is for
%                              subjects
runEffect       = 'random';
isCheckDeriv    = 0;
MaxIteration    = 1000;
verbose         = 1;
groupFit        = [];
fitScale        = 1;
S               = []; 
pcm_vararginoptions(varargin,{'runEffect','isCheckDeriv','MaxIteration',...
    'verbose','groupFit','fitScale','S'});

numSubj     = numel(Y);

% ----------------------------------
if (~iscell(M)) 
    M={M}; 
end; 
numModels = numel(M); 

% Preallocate output structure
T.SN = [1:numSubj]';
T.iterations = zeros(numSubj,1); 
T.time = zeros(numSubj,1); 

% Determine optimal algorithm for each of the models 
M = pcm_optimalAlgorithm(M); 

% --------------------------------------------------------
% Figure out a starting values for the noise parameters
% --------------------------------------------------------
for s = 1:numSubj
    
    % Get Condition and partition vector
    if (iscell(conditionVec))
        cV = conditionVec{s};
        pV = partitionVec{s};
    else
        cV = conditionVec;
        pV = partitionVec;
    end;
    
    % Check if conditionVec is condition or design matrix
    if size(cV,2)==1;
        Z{s}   = pcm_indicatorMatrix('identity_p',cV);
    else
        Z{s} = cV;
    end;
    
    % Set up the main matrices
    [N(s,1),P(s,1)] = size(Y{s});
    numCond= size(Z{s},2);
    YY{s}  = (Y{s} * Y{s}');

    % Depending on the way of dealing with the run effect, set up data
    switch (runEffect)
        case 'random'
            B{s}   = pcm_indicatorMatrix('identity_p',pV);
            X{s}   = [];
        case 'fixed'
            B{s}  =  [];
            X{s}  =  pcm_indicatorMatrix('identity_p',pV);
    end;
    
    % Estimate crossvalidated second moment matrix to get noise and run
    [G_hat(:,:,s),Sig_hat(:,:,s)] = pcm_estGCrossval(Y{s},pV,cV);
    sh              = Sig_hat(:,:,s);
    run0(s,1:numModels)       = log((sum(sum(sh))-trace(sh))/(numCond*(numCond-1)));
    noise0(s,1:numModels)     = log(trace(sh)/numCond-exp(run0(s)));
    
    if (fitScale)
        G0            = mean(G_hat,3);
        g0            = G0(:);
        g_hat         = G_hat(:,:,s);
        g_hat         = g_hat(:);
        scaling       = (g0'*g_hat)/(g0'*g0);
        if ((scaling<10e-6)||~isfinite(scaling));
            scaling = 10e-6;
        end;      % Enforce positive scaling
        scale0(s,1:numModels)   = log(scaling);
    end;
end;

% --------------------------------------------------------------
% Determine starting values for fit: If group fit is given, start
% with those values
for m = 1:numModels
     if (~isempty(groupFit))
        if (size(groupFit{m},2)>1)
            error('Group Fit needs to be a cell array with numParam x 1 vectors for each model'); 
        end; 
        theta0{m}      = groupFit{m}(1:M{m}.numGparams,1);
        indx           = M{m}.numGparams; 
        noise0(:,m)     = groupFit{m}(indx+1:indx+numSubj);
        indx           = indx+numSubj; 
        if (fitScale) 
            scale0(:,m)    = groupFit{m}(indx+1:indx+numSubj);
            indx           = indx+numSubj; 
        end; 
        if (strcmp(runEffect,'random'))
            run0(:,m) = groupFit{m}(indx+1:indx+numSubj);
        end;

     else % No group fit: determine starting values
         if (isfield(M{m},'theta0'))
            theta0{m} = M{m}.theta0;
         else
            theta0{m} = pcm_getStartingval(M{m},mean(G_hat,3));
         end;
    end;
end; 
        


% -----------------------------------------------------
% Loop over subjects and obtain crossvalidated likelihoods
% -----------------------------------------------------
for s = 1:numSubj
    
    % determine training set
    notS    = [1:numSubj];
    notS(s) = [];
    
    % Now loop over models
    for m = 1:numModels
        if (verbose)
            if isfield(M{m},'name');
                fprintf('Crossval Subj: %d model:%s',s,M{m}.name);
            else
                fprintf('Crossval Subj: %d model:%d',s,m);
            end;
        end;
        tic;
        
        % Now fit to all the subject but the left-out one
        switch (M{m}.type)
            case 'fixed'
                if size(M{m}.Gc,3)>1
                    G = mean(M{m}.Gc(:,:,notS),3);
                else
                    G = M{m}.Gc;
                end
                T.iterations(s,m)=0; 
            case 'freedirect'
                G = mean(G_hat(:,:,notS),3);    % uses the mean of all other subjects
                G = pcm_makePD(G);
                T.iterations(s,m)=0; 
            otherwise
                % Generate the starting vector
                x0 = [theta0{m};noise0(notS,m)];
                if (fitScale)
                    x0 = [x0;scale0(notS,m)];
                end;
                if (strcmp(runEffect,'random'))
                    x0  = [x0;run0(notS,m)];       % Start with G-params from group fit
                end;

                % Now do the Group fit
                if (isempty(S))
                    fcn = @(x) pcm_likelihoodGroup(x,{YY{notS}},M{m},{Z{notS}},{X{notS}},P(notS(:)),...
                        'runEffect',{B{notS}},'fitScale',fitScale);
                else
                    fcn = @(x) pcm_likelihoodGroup(x,{YY{notS}},M{m},{Z{notS}},{X{notS}},P(notS(:)),...
                        'runEffect',{B{notS}},'S',S(notS),'fitScale',fitScale);
                end;
                
                switch (M{m}.fitAlgorithm)
                  case 'minimize'
                    [theta,nlv,T.iterations(s,m)] = minimize(x0, fcn, MaxIteration);
                    T.fitLike(s,m)=-nlv(end);
                    T.notSmethod='minimize';
                  case 'NR'
                    try
                      [theta,T.fitLike(s,m),T.iterations(s,m),T.reg(s,m)] = pcm_NR(x0, fcn);
                      T.notSmethod='NR';
                    catch
                      [theta,nlv,T.iterations(s,m)] = minimize(x0, fcn, MaxIteration);
                      T.fitLike(s,m)=-nlv(end);
                      T.notSmethod='minimize';
                    end
                end; 

                theta_hat{m}(:,s)=theta(1:M{m}.numGparams);
                G   = pcm_calculateG(M{m},theta_hat{m}(1:M{m}.numGparams,s));
        end;
        
        % Collect G_pred used for each left-out subject
        G_pred{m}(:,:,s) = G;
        
        % Now get the fit the left-out subject
        % (maximizing scale and noise coefficients)
        x0 = noise0(s);
        if fitScale
            x0 = [x0;scale0(s,m)];
        end;
        if (strcmp(runEffect,'random'))
            x0 = [x0;run0(s,m)];
        end;
        
        if (isempty(S))
            fcn     = @(x) pcm_likelihoodGroup(x,{YY{s}},G,{Z{s}},{X{s}},P(s),...
                'runEffect',{B{s}},'fitScale',fitScale);   % Minize scaling params only
        else
            fcn     = @(x) pcm_likelihoodGroup(x,{YY{s}},G,{Z{s}},{X{s}},P(s),...
                'runEffect',{B{s}},'S',S(s),'fitScale',fitScale);   % Minize scaling params only
        end;
        
        switch (M{m}.fitAlgorithm)
          case 'minimize'
            [theta,nlv] = minimize(x0, fcn, MaxIteration);
            T.likelihood(s,m)=-nlv(end);
            T.Smethod='minimize';
          case 'NR'
            try
              [theta,T.likelihood(s,m)] = pcm_NR(x0, fcn);
              T.Smethod='NR';
            catch
              [theta,nlv] = minimize(x0, fcn, MaxIteration);
              T.likelihood(s,m)=-nlv(end);
              T.Smethod='minimize';
            end
        end
        T.time(s,m)       = toc;
        if verbose
            fprintf('\t Iterations %d, Elapsed time: %3.3f\n',T.iterations(s,m),T.time(s,m));
        end;
        T.noise(s,m) = exp(theta(1));
        if (fitScale)
            T.scale(s,m) = exp(theta(2));
        end;
        if (strcmp(runEffect,'random'))
            T.run(s,m)   = exp(theta(fitScale+1));
        end;
    end;   % Loop over Models 
end; % Loop over Subjects 
