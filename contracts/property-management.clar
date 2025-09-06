
;; title: property-management
;; version: 1.0.0
;; summary: Real Estate Property Management Contract
;; description: Handles property tokenization, stake tracking, rent distribution,
;;              expense management, maintenance proposals, and revenue analytics

;; constants
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_PROPERTY_NOT_FOUND (err u402))
(define-constant ERR_ALREADY_EXISTS (err u403))
(define-constant ERR_INSUFFICIENT_FUNDS (err u404))
(define-constant ERR_INVALID_AMOUNT (err u405))
(define-constant ERR_NOT_STAKEHOLDER (err u406))
(define-constant ERR_PROPOSAL_NOT_FOUND (err u407))
(define-constant ERR_ALREADY_VOTED (err u408))
(define-constant ERR_VOTING_CLOSED (err u409))
(define-constant ERR_INSUFFICIENT_STAKE (err u410))
(define-constant ERR_INVALID_PROPERTY (err u411))
(define-constant ERR_DISTRIBUTION_FAILED (err u412))

(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_STAKE_PERCENTAGE u100) ;; 1% minimum stake
(define-constant MAINTENANCE_VOTE_DURATION u144) ;; ~1 day in blocks
(define-constant PROPOSAL_THRESHOLD u500) ;; 5% stake needed to propose
(define-constant APPROVAL_THRESHOLD u5000) ;; 50% approval needed
(define-constant MAX_PROPERTIES u100)
(define-constant BASIS_POINTS u10000) ;; For percentage calculations

;; data vars
(define-data-var next-property-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var total-properties uint u0)
(define-data-var contract-administrator principal tx-sender)

;; data maps
(define-map properties uint {
  address: (string-ascii 256),
  valuation: uint,
  total-tokens: uint,
  available-tokens: uint,
  rental-yield: uint, ;; Annual yield in basis points
  property-type: (string-ascii 32),
  created-at: uint,
  active: bool,
  total-rent-collected: uint,
  total-expenses: uint
})

(define-map property-stakes { property-id: uint, stakeholder: principal } {
  tokens-owned: uint,
  stake-percentage: uint,
  purchase-price: uint,
  purchase-date: uint,
  total-rent-received: uint
})

(define-map rent-payments { property-id: uint, period: uint } {
  total-amount: uint,
  payment-date: uint,
  distributed: bool,
  per-token-amount: uint
})

(define-map expenses { property-id: uint, expense-id: uint } {
  description: (string-ascii 128),
  amount: uint,
  category: (string-ascii 32),
  date: uint,
  approved: bool,
  paid: bool
})

(define-map maintenance-proposals uint {
  property-id: uint,
  title: (string-ascii 64),
  description: (string-ascii 256),
  estimated-cost: uint,
  proposer: principal,
  votes-for: uint,
  votes-against: uint,
  voting-ends: uint,
  executed: bool,
  approved: bool
})

(define-map maintenance-votes { proposal-id: uint, voter: principal } bool)

(define-map property-revenue uint {
  total-rent: uint,
  total-expenses: uint,
  net-income: uint,
  last-updated: uint
})

;; public functions

;; Tokenize a new property
(define-public (tokenize-property (address (string-ascii 256))
                                  (valuation uint)
                                  (total-tokens uint)
                                  (rental-yield uint)
                                  (property-type (string-ascii 32)))
  (let ((property-id (var-get next-property-id)))
    (asserts! (is-eq tx-sender (var-get contract-administrator)) ERR_UNAUTHORIZED)
    (asserts! (> valuation u0) ERR_INVALID_AMOUNT)
    (asserts! (> total-tokens u0) ERR_INVALID_AMOUNT)
    (asserts! (< (var-get total-properties) MAX_PROPERTIES) ERR_UNAUTHORIZED)
    
    (map-set properties property-id {
      address: address,
      valuation: valuation,
      total-tokens: total-tokens,
      available-tokens: total-tokens,
      rental-yield: rental-yield,
      property-type: property-type,
      created-at: block-height,
      active: true,
      total-rent-collected: u0,
      total-expenses: u0
    })
    
    (map-set property-revenue property-id {
      total-rent: u0,
      total-expenses: u0,
      net-income: u0,
      last-updated: block-height
    })
    
    (var-set next-property-id (+ property-id u1))
    (var-set total-properties (+ (var-get total-properties) u1))
    (ok property-id)
  )
)

;; Purchase property tokens
(define-public (purchase-tokens (property-id uint) (token-amount uint))
  (let ((property-data (map-get? properties property-id))
        (stake-key { property-id: property-id, stakeholder: tx-sender }))
    (asserts! (is-some property-data) ERR_PROPERTY_NOT_FOUND)
    
    (let ((property (unwrap-panic property-data))
          (token-price (/ (get valuation property) (get total-tokens property)))
          (total-cost (* token-amount token-price))
          (existing-stake (map-get? property-stakes stake-key)))
      
      (asserts! (get active property) ERR_INVALID_PROPERTY)
      (asserts! (>= (get available-tokens property) token-amount) ERR_INSUFFICIENT_FUNDS)
      
      (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
      
      (let ((new-stake-percentage (/ (* token-amount BASIS_POINTS) (get total-tokens property))))
        
        (if (is-some existing-stake)
          (let ((current-stake (unwrap-panic existing-stake)))
            (map-set property-stakes stake-key {
              tokens-owned: (+ (get tokens-owned current-stake) token-amount),
              stake-percentage: (+ (get stake-percentage current-stake) new-stake-percentage),
              purchase-price: (+ (get purchase-price current-stake) total-cost),
              purchase-date: (get purchase-date current-stake),
              total-rent-received: (get total-rent-received current-stake)
            }))
          (map-set property-stakes stake-key {
            tokens-owned: token-amount,
            stake-percentage: new-stake-percentage,
            purchase-price: total-cost,
            purchase-date: block-height,
            total-rent-received: u0
          })
        )
        
        (map-set properties property-id
          (merge property { available-tokens: (- (get available-tokens property) token-amount) }))
        
        (ok "Tokens purchased successfully")
      )
    )
  )
)

;; Record rent payment for a property
(define-public (record-rent-payment (property-id uint) (amount uint) (period uint))
  (let ((property-data (map-get? properties property-id))
        (payment-key { property-id: property-id, period: period }))
    (asserts! (is-eq tx-sender (var-get contract-administrator)) ERR_UNAUTHORIZED)
    (asserts! (is-some property-data) ERR_PROPERTY_NOT_FOUND)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (is-none (map-get? rent-payments payment-key)) ERR_ALREADY_EXISTS)
    
    (let ((property (unwrap-panic property-data))
          (per-token-amount (/ amount (get total-tokens property))))
      
      (map-set rent-payments payment-key {
        total-amount: amount,
        payment-date: block-height,
        distributed: false,
        per-token-amount: per-token-amount
      })
      
      (map-set properties property-id
        (merge property { total-rent-collected: (+ (get total-rent-collected property) amount) }))
      
      (let ((revenue-data (unwrap-panic (map-get? property-revenue property-id))))
        (map-set property-revenue property-id
          (merge revenue-data {
            total-rent: (+ (get total-rent revenue-data) amount),
            net-income: (+ (get net-income revenue-data) amount),
            last-updated: block-height
          }))
      )
      
      (ok "Rent payment recorded")
    )
  )
)

;; Claim rent distribution for stakeholder
(define-public (claim-rent-distribution (property-id uint) (period uint))
  (let ((stake-key { property-id: property-id, stakeholder: tx-sender })
        (payment-key { property-id: property-id, period: period })
        (stake-data (map-get? property-stakes stake-key))
        (payment-data (map-get? rent-payments payment-key)))
    
    (asserts! (is-some stake-data) ERR_NOT_STAKEHOLDER)
    (asserts! (is-some payment-data) ERR_PROPERTY_NOT_FOUND)
    
    (let ((stake (unwrap-panic stake-data))
          (payment (unwrap-panic payment-data))
          (distribution-amount (* (get tokens-owned stake) (get per-token-amount payment))))
      
      (asserts! (> distribution-amount u0) ERR_INVALID_AMOUNT)
      
      (try! (as-contract (stx-transfer? distribution-amount tx-sender (get stakeholder stake-key))))
      
      (map-set property-stakes stake-key
        (merge stake { total-rent-received: (+ (get total-rent-received stake) distribution-amount) }))
      
      (ok distribution-amount)
    )
  )
)

;; Log property expense
(define-public (log-expense (property-id uint)
                           (description (string-ascii 128))
                           (amount uint)
                           (category (string-ascii 32))
                           (expense-id uint))
  (let ((property-data (map-get? properties property-id))
        (expense-key { property-id: property-id, expense-id: expense-id }))
    (asserts! (is-eq tx-sender (var-get contract-administrator)) ERR_UNAUTHORIZED)
    (asserts! (is-some property-data) ERR_PROPERTY_NOT_FOUND)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (map-set expenses expense-key {
      description: description,
      amount: amount,
      category: category,
      date: block-height,
      approved: false,
      paid: false
    })
    
    (let ((property (unwrap-panic property-data)))
      (map-set properties property-id
        (merge property { total-expenses: (+ (get total-expenses property) amount) }))
      
      (let ((revenue-data (unwrap-panic (map-get? property-revenue property-id))))
        (map-set property-revenue property-id
          (merge revenue-data {
            total-expenses: (+ (get total-expenses revenue-data) amount),
            net-income: (- (get net-income revenue-data) amount),
            last-updated: block-height
          }))
      )
    )
    
    (ok "Expense logged successfully")
  )
)

;; Create maintenance proposal
(define-public (create-maintenance-proposal (property-id uint)
                                           (title (string-ascii 64))
                                           (description (string-ascii 256))
                                           (estimated-cost uint))
  (let ((stake-key { property-id: property-id, stakeholder: tx-sender })
        (stake-data (map-get? property-stakes stake-key))
        (proposal-id (var-get next-proposal-id)))
    
    (asserts! (is-some stake-data) ERR_NOT_STAKEHOLDER)
    (asserts! (>= (get stake-percentage (unwrap-panic stake-data)) PROPOSAL_THRESHOLD) ERR_INSUFFICIENT_STAKE)
    (asserts! (> estimated-cost u0) ERR_INVALID_AMOUNT)
    
    (map-set maintenance-proposals proposal-id {
      property-id: property-id,
      title: title,
      description: description,
      estimated-cost: estimated-cost,
      proposer: tx-sender,
      votes-for: u0,
      votes-against: u0,
      voting-ends: (+ block-height MAINTENANCE_VOTE_DURATION),
      executed: false,
      approved: false
    })
    
    (var-set next-proposal-id (+ proposal-id u1))
    (ok proposal-id)
  )
)

;; Vote on maintenance proposal
(define-public (vote-maintenance-proposal (proposal-id uint) (support bool))
  (let ((proposal-data (map-get? maintenance-proposals proposal-id))
        (vote-key { proposal-id: proposal-id, voter: tx-sender }))
    
    (asserts! (is-some proposal-data) ERR_PROPOSAL_NOT_FOUND)
    (asserts! (is-none (map-get? maintenance-votes vote-key)) ERR_ALREADY_VOTED)
    
    (let ((proposal (unwrap-panic proposal-data))
          (stake-key { property-id: (get property-id proposal), stakeholder: tx-sender })
          (stake-data (map-get? property-stakes stake-key)))
      
      (asserts! (is-some stake-data) ERR_NOT_STAKEHOLDER)
      (asserts! (<= block-height (get voting-ends proposal)) ERR_VOTING_CLOSED)
      
      (let ((voting-power (get stake-percentage (unwrap-panic stake-data))))
        (map-set maintenance-votes vote-key true)
        
        (if support
          (map-set maintenance-proposals proposal-id
            (merge proposal { votes-for: (+ (get votes-for proposal) voting-power) }))
          (map-set maintenance-proposals proposal-id
            (merge proposal { votes-against: (+ (get votes-against proposal) voting-power) })))
        
        (ok "Vote recorded")
      )
    )
  )
)

;; read only functions

(define-read-only (get-property-info (property-id uint))
  (map-get? properties property-id)
)

(define-read-only (get-stakeholder-info (property-id uint) (stakeholder principal))
  (map-get? property-stakes { property-id: property-id, stakeholder: stakeholder })
)

(define-read-only (get-rent-payment-info (property-id uint) (period uint))
  (map-get? rent-payments { property-id: property-id, period: period })
)

(define-read-only (get-expense-info (property-id uint) (expense-id uint))
  (map-get? expenses { property-id: property-id, expense-id: expense-id })
)

(define-read-only (get-maintenance-proposal (proposal-id uint))
  (map-get? maintenance-proposals proposal-id)
)

(define-read-only (get-property-revenue (property-id uint))
  (map-get? property-revenue property-id)
)

(define-read-only (get-total-properties)
  (var-get total-properties)
)

(define-read-only (get-next-property-id)
  (var-get next-property-id)
)

(define-read-only (get-contract-administrator)
  (var-get contract-administrator)
)

(define-read-only (has-voted-on-maintenance (proposal-id uint) (voter principal))
  (is-some (map-get? maintenance-votes { proposal-id: proposal-id, voter: voter }))
)
