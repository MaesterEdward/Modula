;; Blockchain Module Store - Developer Module Ecosystem
;; Composable blockchain modules for rapid dApp development

;; Constants
(define-constant store-operator tx-sender)
(define-constant err-operator-required (err u600))
(define-constant err-module-unavailable (err u601))
(define-constant err-insufficient-privileges (err u602))
(define-constant err-payment-failed (err u603))
(define-constant err-module-conflict (err u604))
(define-constant err-parameter-invalid (err u605))

;; Data Variables
(define-data-var store-commission uint u350) ;; 3.5% store commission

;; Data Maps
(define-map blockchain-modules
  { module-key: (string-ascii 36) }
  {
    creator: principal,
    module-name: (string-utf8 90),
    module-summary: (string-utf8 450),
    domain: (string-ascii 26), ;; "payment", "identity", "voting", "token", "storage"
    unit-price: uint,
    subscription-rate: uint,
    integration-count: uint,
    module-earnings: uint,
    available: bool,
    code-location: (string-ascii 56) ;; IPFS hash for module code
  }
)

(define-map developer-access
  { developer: principal, module-key: (string-ascii 36) }
  {
    access-model: (string-ascii 12), ;; "subscription" or "purchased"
    valid-through: uint,
    integrations-left: uint,
    total-investment: uint
  }
)

(define-map module-ratings
  { module-key: (string-ascii 36), developer: principal }
  {
    performance-rating: uint, ;; 1-5 performance score
    review-comment: (string-utf8 380),
    rating-timestamp: uint
  }
)

(define-map creator-balances principal uint)

;; Read-only functions
(define-read-only (get-module (module-key (string-ascii 36)))
  (map-get? blockchain-modules { module-key: module-key })
)

(define-read-only (get-access (developer principal) (module-key (string-ascii 36)))
  (map-get? developer-access { developer: developer, module-key: module-key })
)

(define-read-only (get-module-rating (module-key (string-ascii 36)) (developer principal))
  (map-get? module-ratings { module-key: module-key, developer: developer })
)

(define-read-only (get-creator-balance (creator principal))
  (default-to u0 (map-get? creator-balances creator))
)

(define-read-only (can-integrate-module (developer principal) (module-key (string-ascii 36)))
  (let (
    (access-info (get-access developer module-key))
  )
    (match access-info
      access-data
        (or 
          (> (get integrations-left access-data) u0)
          (> (get valid-through access-data) block-height)
        )
      false
    )
  )
)

;; Public functions

;; Publish new module
(define-public (publish-module
    (module-key (string-ascii 36))
    (module-name (string-utf8 90))
    (module-summary (string-utf8 450))
    (domain (string-ascii 26))
    (unit-price uint)
    (subscription-rate uint)
    (code-location (string-ascii 56))
  )
  (let (
    (existing-module (get-module module-key))
  )
    (asserts! (is-none existing-module) err-module-conflict)
    (ok (map-set blockchain-modules
      { module-key: module-key }
      {
        creator: tx-sender,
        module-name: module-name,
        module-summary: module-summary,
        domain: domain,
        unit-price: unit-price,
        subscription-rate: subscription-rate,
        integration-count: u0,
        module-earnings: u0,
        available: true,
        code-location: code-location
      }
    ))
  )
)

;; Subscribe to module access
(define-public (subscribe-to-module (module-key (string-ascii 36)))
  (let (
    (module-info (unwrap! (get-module module-key) err-module-unavailable))
    (subscription-fee (get subscription-rate module-info))
    (store-fee (/ (* subscription-fee (var-get store-commission)) u10000))
    (creator-payment (- subscription-fee store-fee))
  )
    (asserts! (get available module-info) err-module-unavailable)
    (try! (stx-transfer? subscription-fee tx-sender (as-contract tx-sender)))
    
    ;; Update module metrics
    (map-set blockchain-modules
      { module-key: module-key }
      (merge module-info {
        integration-count: (+ (get integration-count module-info) u1),
        module-earnings: (+ (get module-earnings module-info) subscription-fee)
      })
    )
    
    ;; Grant subscription access
    (map-set developer-access
      { developer: tx-sender, module-key: module-key }
      {
        access-model: "subscription",
        valid-through: (+ block-height u5760), ;; 40 days
        integrations-left: u0,
        total-investment: subscription-fee
      }
    )
    
    ;; Pay creator
    (map-set creator-balances
      (get creator module-info)
      (+ (get-creator-balance (get creator module-info)) creator-payment)
    )
    
    (ok true)
  )
)

;; Purchase module integrations
(define-public (purchase-integrations (module-key (string-ascii 36)) (integration-count uint))
  (let (
    (module-info (unwrap! (get-module module-key) err-module-unavailable))
    (total-cost (* (get unit-price module-info) integration-count))
    (store-fee (/ (* total-cost (var-get store-commission)) u10000))
    (creator-payment (- total-cost store-fee))
  )
    (asserts! (get available module-info) err-module-unavailable)
    (try! (stx-transfer? total-cost tx-sender (as-contract tx-sender)))
    
    ;; Update module metrics
    (map-set blockchain-modules
      { module-key: module-key }
      (merge module-info {
        integration-count: (+ (get integration-count module-info) u1),
        module-earnings: (+ (get module-earnings module-info) total-cost)
      })
    )
    
    ;; Update or create access record
    (let (
      (existing-access (get-access tx-sender module-key))
    )
      (match existing-access
        access-data
          (map-set developer-access
            { developer: tx-sender, module-key: module-key }
            (merge access-data {
              integrations-left: (+ (get integrations-left access-data) integration-count),
              total-investment: (+ (get total-investment access-data) total-cost)
            })
          )
        (map-set developer-access
          { developer: tx-sender, module-key: module-key }
          {
            access-model: "purchased",
            valid-through: u0,
            integrations-left: integration-count,
            total-investment: total-cost
          }
        )
      )
    )
    
    ;; Pay creator
    (map-set creator-balances
      (get creator module-info)
      (+ (get-creator-balance (get creator module-info)) creator-payment)
    )
    
    (ok true)
  )
)

;; Integrate module (consumes access)
(define-public (integrate-module (module-key (string-ascii 36)))
  (let (
    (module-info (unwrap! (get-module module-key) err-module-unavailable))
    (access-info (unwrap! (get-access tx-sender module-key) err-insufficient-privileges))
  )
    (asserts! (get available module-info) err-module-unavailable)
    
    ;; Validate and consume access
    (if (is-eq (get access-model access-info) "purchased")
      (begin
        (asserts! (> (get integrations-left access-info) u0) err-insufficient-privileges)
        (map-set developer-access
          { developer: tx-sender, module-key: module-key }
          (merge access-info {
            integrations-left: (- (get integrations-left access-info) u1)
          })
        )
      )
      (asserts! (> (get valid-through access-info) block-height) err-insufficient-privileges)
    )
    
    (ok true)
  )
)

;; Rate a module
(define-public (rate-module
    (module-key (string-ascii 36))
    (performance-rating uint)
    (review-comment (string-utf8 380))
  )
  (let (
    (module-info (unwrap! (get-module module-key) err-module-unavailable))
  )
    (asserts! (and (>= performance-rating u1) (<= performance-rating u5)) err-parameter-invalid)
    (asserts! (can-integrate-module tx-sender module-key) err-insufficient-privileges)
    
    (ok (map-set module-ratings
      { module-key: module-key, developer: tx-sender }
      {
        performance-rating: performance-rating,
        review-comment: review-comment,
        rating-timestamp: block-height
      }
    ))
  )
)

;; Creator withdraws earnings
(define-public (withdraw-creator-balance)
  (let (
    (balance (get-creator-balance tx-sender))
  )
    (asserts! (> balance u0) err-module-unavailable)
    (try! (as-contract (stx-transfer? balance tx-sender tx-sender)))
    (map-set creator-balances tx-sender u0)
    (ok balance)
  )
)

;; Update module details
(define-public (modify-module
    (module-key (string-ascii 36))
    (module-name (string-utf8 90))
    (module-summary (string-utf8 450))
    (unit-price uint)
    (subscription-rate uint)
    (code-location (string-ascii 56))
    (available bool)
  )
  (let (
    (module-info (unwrap! (get-module module-key) err-module-unavailable))
  )
    (asserts! (is-eq (get creator module-info) tx-sender) err-insufficient-privileges)
    
    (ok (map-set blockchain-modules
      { module-key: module-key }
      (merge module-info {
        module-name: module-name,
        module-summary: module-summary,
        unit-price: unit-price,
        subscription-rate: subscription-rate,
        code-location: code-location,
        available: available
      })
    ))
  )
)

;; Store operator admin function
(define-public (adjust-store-commission (new-commission uint))
  (begin
    (asserts! (is-eq tx-sender store-operator) err-operator-required)
    (asserts! (<= new-commission u800) err-parameter-invalid) ;; Max 8%
    (ok (var-set store-commission new-commission))
  )
)