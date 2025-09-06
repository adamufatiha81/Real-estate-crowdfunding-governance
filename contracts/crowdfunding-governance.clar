
;; title: crowdfunding-governance
;; version: 1.0.0
;; summary: Real Estate Crowdfunding Governance Contract
;; description: Manages investor registration, token accounting, funding rounds,
;;              proposal creation, weighted voting, and secure execution guardrails

;; constants
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_ALREADY_REGISTERED (err u402))
(define-constant ERR_NOT_REGISTERED (err u403))
(define-constant ERR_INSUFFICIENT_FUNDS (err u404))
(define-constant ERR_FUNDING_CLOSED (err u405))
(define-constant ERR_MIN_INVESTMENT_NOT_MET (err u406))
(define-constant ERR_PROPOSAL_NOT_FOUND (err u407))
(define-constant ERR_PROPOSAL_EXPIRED (err u408))
(define-constant ERR_ALREADY_VOTED (err u409))
(define-constant ERR_VOTING_CLOSED (err u410))
(define-constant ERR_INSUFFICIENT_VOTES (err u411))
(define-constant ERR_INVALID_AMOUNT (err u412))

(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_INVESTMENT u100000) ;; 0.1 STX minimum
(define-constant MAX_INVESTORS u500)
(define-constant PROPOSAL_DURATION u144) ;; ~1 day in blocks
(define-constant EXECUTION_THRESHOLD u6000) ;; 60% approval needed

;; data vars
(define-data-var total-investment uint u0)
(define-data-var total-investors uint u0)
(define-data-var funding-active bool true)
(define-data-var next-proposal-id uint u1)
(define-data-var contract-balance uint u0)

;; data maps
(define-map investors principal {
  stake: uint,
  voting-power: uint,
  investment-date: uint,
  kyc-verified: bool
})

(define-map funding-rounds uint {
  target-amount: uint,
  current-amount: uint,
  start-block: uint,
  end-block: uint,
  active: bool
})

(define-map proposals uint {
  title: (string-ascii 64),
  description: (string-ascii 256),
  proposer: principal,
  amount: uint,
  recipient: principal,
  votes-for: uint,
  votes-against: uint,
  start-block: uint,
  end-block: uint,
  executed: bool,
  passed: bool
})

(define-map proposal-votes { proposal-id: uint, voter: principal } bool)

;; public functions

;; Investor registration with KYC verification
(define-public (register-investor)
  (let ((sender tx-sender)
        (current-investors (var-get total-investors)))
    (asserts! (< current-investors MAX_INVESTORS) ERR_UNAUTHORIZED)
    (asserts! (is-none (map-get? investors sender)) ERR_ALREADY_REGISTERED)
    (map-set investors sender {
      stake: u0,
      voting-power: u0,
      investment-date: block-height,
      kyc-verified: false
    })
    (var-set total-investors (+ current-investors u1))
    (ok "Investor registered successfully")
  )
)

;; Verify investor KYC (only contract owner)
(define-public (verify-investor-kyc (investor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-some (map-get? investors investor)) ERR_NOT_REGISTERED)
    (map-set investors investor 
      (merge (unwrap-panic (map-get? investors investor))
             { kyc-verified: true }))
    (ok "KYC verification completed")
  )
)

;; Make investment contribution
(define-public (contribute (amount uint))
  (let ((sender tx-sender)
        (investor-data (map-get? investors sender))
        (current-total (var-get total-investment)))
    (asserts! (var-get funding-active) ERR_FUNDING_CLOSED)
    (asserts! (>= amount MIN_INVESTMENT) ERR_MIN_INVESTMENT_NOT_MET)
    (asserts! (is-some investor-data) ERR_NOT_REGISTERED)
    (asserts! (get kyc-verified (unwrap-panic investor-data)) ERR_UNAUTHORIZED)
    
    (try! (stx-transfer? amount sender (as-contract tx-sender)))
    
    (let ((current-stake (get stake (unwrap-panic investor-data)))
          (new-stake (+ current-stake amount))
          (new-voting-power (/ (* new-stake u10000) (+ current-total amount))))
      
      (map-set investors sender
        (merge (unwrap-panic investor-data)
               { stake: new-stake,
                 voting-power: new-voting-power }))
      
      (var-set total-investment (+ current-total amount))
      (var-set contract-balance (+ (var-get contract-balance) amount))
      (ok "Investment contribution successful")
    )
  )
)

;; Create governance proposal
(define-public (create-proposal (title (string-ascii 64)) 
                               (description (string-ascii 256))
                               (amount uint)
                               (recipient principal))
  (let ((sender tx-sender)
        (investor-data (map-get? investors sender))
        (proposal-id (var-get next-proposal-id)))
    (asserts! (is-some investor-data) ERR_NOT_REGISTERED)
    (asserts! (> (get voting-power (unwrap-panic investor-data)) u100) ERR_UNAUTHORIZED) ;; Min 1% voting power
    (asserts! (<= amount (var-get contract-balance)) ERR_INSUFFICIENT_FUNDS)
    
    (map-set proposals proposal-id {
      title: title,
      description: description,
      proposer: sender,
      amount: amount,
      recipient: recipient,
      votes-for: u0,
      votes-against: u0,
      start-block: block-height,
      end-block: (+ block-height PROPOSAL_DURATION),
      executed: false,
      passed: false
    })
    
    (var-set next-proposal-id (+ proposal-id u1))
    (ok proposal-id)
  )
)

;; Vote on proposal
(define-public (vote (proposal-id uint) (support bool))
  (let ((sender tx-sender)
        (investor-data (map-get? investors sender))
        (proposal-data (map-get? proposals proposal-id))
        (vote-key { proposal-id: proposal-id, voter: sender }))
    
    (asserts! (is-some investor-data) ERR_NOT_REGISTERED)
    (asserts! (is-some proposal-data) ERR_PROPOSAL_NOT_FOUND)
    (asserts! (is-none (map-get? proposal-votes vote-key)) ERR_ALREADY_VOTED)
    
    (let ((proposal (unwrap-panic proposal-data))
          (investor (unwrap-panic investor-data))
          (voting-power (get voting-power investor)))
      
      (asserts! (<= block-height (get end-block proposal)) ERR_PROPOSAL_EXPIRED)
      (asserts! (not (get executed proposal)) ERR_VOTING_CLOSED)
      
      (map-set proposal-votes vote-key true)
      
      (if support
        (map-set proposals proposal-id
          (merge proposal { votes-for: (+ (get votes-for proposal) voting-power) }))
        (map-set proposals proposal-id
          (merge proposal { votes-against: (+ (get votes-against proposal) voting-power) })))
      
      (ok "Vote cast successfully")
    )
  )
)

;; Execute approved proposal
(define-public (execute-proposal (proposal-id uint))
  (let ((proposal-data (map-get? proposals proposal-id)))
    (asserts! (is-some proposal-data) ERR_PROPOSAL_NOT_FOUND)
    
    (let ((proposal (unwrap-panic proposal-data))
          (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
          (approval-rate (if (> total-votes u0)
                           (/ (* (get votes-for proposal) u10000) total-votes)
                           u0)))
      
      (asserts! (> block-height (get end-block proposal)) ERR_VOTING_CLOSED)
      (asserts! (not (get executed proposal)) ERR_VOTING_CLOSED)
      (asserts! (>= approval-rate EXECUTION_THRESHOLD) ERR_INSUFFICIENT_VOTES)
      (asserts! (<= (get amount proposal) (var-get contract-balance)) ERR_INSUFFICIENT_FUNDS)
      
      (try! (as-contract (stx-transfer? (get amount proposal) tx-sender (get recipient proposal))))
      
      (map-set proposals proposal-id
        (merge proposal { executed: true, passed: true }))
      
      (var-set contract-balance (- (var-get contract-balance) (get amount proposal)))
      (ok "Proposal executed successfully")
    )
  )
)

;; Close funding round (only contract owner)
(define-public (close-funding)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set funding-active false)
    (ok "Funding round closed")
  )
)

;; read only functions

(define-read-only (get-investor-info (investor principal))
  (map-get? investors investor)
)

(define-read-only (get-proposal-info (proposal-id uint))
  (map-get? proposals proposal-id)
)

(define-read-only (get-total-investment)
  (var-get total-investment)
)

(define-read-only (get-total-investors)
  (var-get total-investors)
)

(define-read-only (get-contract-balance)
  (var-get contract-balance)
)

(define-read-only (is-funding-active)
  (var-get funding-active)
)

(define-read-only (has-voted (proposal-id uint) (voter principal))
  (is-some (map-get? proposal-votes { proposal-id: proposal-id, voter: voter }))
)

(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id)
)
