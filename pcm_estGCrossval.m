function [G,Sig]=pcm_estGCrossval(B,partition,conditionVec,X)
% function [G,Sigma]=pcm_estGCrossval(Y,partition,conditionVec,X);
% Estimates the second moment matrix using crossvalidation across partitions 
% (imaging runs), making the estimate unbiased 
% The estimated second moment matrix will the matching SMM to the
% crossvalidated Mahalanobis distance (see Walther et al., 2015).  
% If the optional input argument X is given, then the data will be combined
% across partitions in an optimal way, taking into account the different
% variabilities of the estimators. In this case, it is also allowed that
% not every regressor is used in every partition (although this is not recommended).
% 
% INPUT:
%  B           : Noise-normalized activation patterns, a N x P matrix
%                If X is provided for optimal weighting of the regressors,
%                it is important also to submit all regressors of
%                no-interest (i.e. intercepts, etc), such that their value
%                can be taken into account 
%  partition   : N x 1 integer value that indicates the partition for crossvalidation (typically run number)
%                These need to be between 1...M, zeros are being ignored 
%                if the Partition vector is shorter than N, it is assumed that the
%                last regressors are intercept for the different runs-as is
%                usual in SPM.
%  conditionVec: N x 1 vector of conditions, zeros will be ignored as
%                regressors of no interest. If conditionVec is shorter than 
%                N, it is assumed that all remaining numbers are 0. 
%  X           : T x N Design matrix that is used to estimate from the first
%                level. This is an optional input parameter to optimally combine the beta weights 
%                across partitions. If temporal filtering / prewhitening is applied 
%                to the data, this needs to be the filtered design matrix. 
%                - If X is given, B needs to also contain the 
%                   Coefficients of no interest. 
%                - If X is not given, it assumes that the Beta-weights are i.i.d 
% OUTPUT: 
%   G          : Estimated second moment matrix
%   Sig        : a KxK covariance matrix of the beta estimates across
%               different imaging runs. 
% Joern Diedrichsen 
% 2/2016 

[N,numVox]          = size(B); 
part                = unique(partition)';
part(part==0)       = []; % Ignore the zero partitions 
if isvector(conditionVec)
    cond            = unique(conditionVec);
    cond(cond==0)   = [];
else
    cond            = 1:size(conditionVec,2);
end
numPart = numel(part);
numCond = numel(cond);%max(conditionVec); 

% Check on design matrix 
if (nargin>3 && ~isempty(X))  
    numReg     = size(X,2);             % Number of regressors in the first-level design matrix 
    if (numReg ~=N) 
        error('For optimal integration of beta weights, all N regressors (including no-interest) need to be submitted in Y'); 
    end; 
end; 

% Check length of partition vector  
missing = N-length(partition); 
if missing > 0 
    partition  = [partition;[1:missing]']; % Asssume that these are run intercepts 
end; 

% Check if condition vector is vector or matrix,
% then make second-level design matrix, pulling through the regressors of no-interest 
missing = N-length(conditionVec);
if ~isvector(conditionVec) % when design matrix has passed
    Z = conditionVec;
else
    if missing>0
        conditionVec = [conditionVec;zeros(missing,1)];
    end    
    Z = pcm_indicatorMatrix('identity_p',conditionVec);
end
% Deal with number of no-interest regressors
numNonInterest = sum(all(Z==0,2));      
Z(all(Z==0,2),end+[1:numNonInterest]) = eye(numNonInterest);
% numNonInterest = sum(conditionVec==0);      
% Z(conditionVec==0,end+[1:numNonInterest])=eye(numNonInterest);


% Check length of condition vector 

A = zeros(numCond,numVox,numPart);           % Allocate memory 
Bp = zeros(numCond,numVox);

% Estimate condition means within each run and crossvalidate 
for i=1:numPart 
    % Left-out partition 
    indxA = partition==part(i);
    Za    = Z(indxA,:); 
    Za    = Za(:,any(Za,1));       % restrict to regressors that are not all 0
    Ba    = B(indxA,:);            % Get regression coefficients 

    % remainder of conditions 
    indxB = partition~=part(i);
    Zb    = Z(indxB,:); 
    Zb    = Zb(:,any(Zb,1));    % Restrict to regressors that are not all 0 
    Bb    = B(indxB,:);
    
    % valid conditions of interest
    interestA = find(any(Z(indxA,1:numCond),1));
    interestB = find(any(Z(indxB,1:numCond),1));
    
    % Use design matrix if present to get GLS estimate 
   if (nargin>3 & ~isempty(X))
        Xa      = X(:,indxA);
        Xb      = X(:,indxB);
        indxX   = any(Xa,1);    % Restrict to regressors that are used in this partition
        Za      = Xa*Za; 
        Za      = Za(:,indxX); 
        Zb      = Xb*Zb; 
        Ba      = Xa(:,indxX)*Ba(indxX,:);
        Bb      = Xb*Bb; 
   end; 
    a     = pinv(Za)*Ba;
    b     = pinv(Zb)*Bb;
    %A(:,:,i) = a(1:numCond,:); 
    %G(:,:,i)= A(:,:,i)*b(1:numCond,:)'/numVox;      % Note that this is normalised to the number of voxels 
    A(interestA,:,i)    = a(1:length(interestA),:); 
    Bp(interestB,:)     = b(1:length(interestB),:);
    G(:,:,i)= A(:,:,i)*Bp'/numVox;      % Note that this is normalised to the number of voxels 
end; 
G=mean(G,3); 

% If requested, also calculate the estimated variance-covariance 
% matrix from the residual across folds. 
if (nargout>1) 
    R=bsxfun(@minus,A,sum(A,3)/numPart);
    for i=1:numPart
        Sig(:,:,i)=R(:,:,i)*R(:,:,i)'/numVox;
    end;
    Sig=sum(Sig,3)/(numPart-1);
end; 