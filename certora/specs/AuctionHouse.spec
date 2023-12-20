ghost uint256 aipStore;
ghost uint256 aipLoad;

hook Sstore nAuctionsInProgress uint256 _aipStore STORAGE {
   aipStore = _aipStore;
}

hook Sload uint256 _aipLoad nAuctionsInProgress STORAGE {
   aipLoad = _aipLoad;
}

rule bidSpec() {

    env e; bytes32 loanId;
    
    bid(e, loanId);

    assert aipLoad != 0 => aipStore < aipLoad;
}