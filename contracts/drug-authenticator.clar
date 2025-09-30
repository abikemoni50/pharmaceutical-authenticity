;; Drug Authenticator Contract
;; Track pharmaceutical batches, monitor storage conditions, verify authenticity at each
;; supply chain step, and alert authorities to suspected counterfeits

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-BATCH-NOT-FOUND (err u101))
(define-constant ERR-BATCH-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-TEMPERATURE (err u103))
(define-constant ERR-COUNTERFEIT-FLAGGED (err u104))
(define-constant ERR-EXPIRED-BATCH (err u105))
(define-constant ERR-INVALID-PARTICIPANT (err u106))
(define-constant ERR-TEMPERATURE-VIOLATION (err u107))
(define-constant ERR-ALREADY-VERIFIED (err u108))
(define-constant ERR-INSUFFICIENT-PERMISSIONS (err u109))
(define-constant ERR-INVALID-STORAGE-CONDITIONS (err u110))

;; Supply Chain Roles
(define-constant ROLE-MANUFACTURER u1)
(define-constant ROLE-DISTRIBUTOR u2)
(define-constant ROLE-PHARMACY u3)
(define-constant ROLE-REGULATOR u4)
(define-constant ROLE-TRANSPORTER u5)

;; Batch Status Constants
(define-constant STATUS-MANUFACTURED u0)
(define-constant STATUS-IN-TRANSIT u1)
(define-constant STATUS-DISTRIBUTED u2)
(define-constant STATUS-DISPENSED u3)
(define-constant STATUS-FLAGGED u4)
(define-constant STATUS-RECALLED u5)

;; Temperature Ranges (in Celsius)
(define-constant MIN-TEMP -40)
(define-constant MAX-TEMP 50)
(define-constant COLD-CHAIN-MIN 2)
(define-constant COLD-CHAIN-MAX 8)

;; Data Variables
(define-data-var batch-counter uint u0)
(define-data-var location-counter uint u0)
(define-data-var counterfeit-alerts uint u0)
(define-data-var total-batches-tracked uint u0)

;; Data Maps
(define-map drug-batches
  (string-ascii 50) ;; batch-id
  {
    manufacturer: principal,
    drug-name: (string-utf8 100),
    ndc-code: (string-ascii 20),
    units-produced: uint,
    manufacturing-date: uint,
    expiration-date: uint,
    status: uint,
    is-cold-chain: bool,
    min-temp-required: int,
    max-temp-required: int,
    created-at: uint,
    last-updated: uint,
    is-authentic: bool,
    counterfeit-flags: uint
  }
)

(define-map supply-chain-participants
  principal
  {
    name: (string-utf8 100),
    role: uint,
    authorized: bool,
    location: (string-utf8 100),
    registration-date: uint,
    total-batches-handled: uint
  }
)

(define-map batch-locations
  { batch-id: (string-ascii 50), location-id: uint }
  {
    handler: principal,
    location-name: (string-utf8 100),
    timestamp: uint,
    temperature: int,
    humidity: uint,
    notes: (string-utf8 200),
    verified: bool
  }
)

(define-map batch-location-history
  (string-ascii 50)
  (list 20 uint)
)

(define-map temperature-readings
  { batch-id: (string-ascii 50), reading-id: uint }
  {
    temperature: int,
    humidity: uint,
    timestamp: uint,
    location: (string-utf8 100),
    device-id: (string-ascii 30),
    within-range: bool
  }
)

(define-map counterfeit-reports
  uint
  {
    batch-id: (string-ascii 50),
    reporter: principal,
    location: (string-utf8 100),
    reason: (string-utf8 300),
    timestamp: uint,
    investigated: bool,
    confirmed: bool
  }
)

(define-map batch-verifications
  { batch-id: (string-ascii 50), verifier: principal }
  {
    verified-at: uint,
    location: (string-utf8 100),
    verification-status: bool,
    notes: (string-utf8 200)
  }
)

(define-map regulatory-compliance
  (string-ascii 50)
  {
    fda-approved: bool,
    dscsa-compliant: bool,
    gmp-certified: bool,
    last-inspection: uint,
    compliance-score: uint,
    violations: uint
  }
)

(define-data-var reading-counter uint u0)
(define-data-var report-counter uint u0)

;; Private Functions
(define-private (is-authorized-participant (participant principal))
  (match (map-get? supply-chain-participants participant)
    participant-info (get authorized participant-info)
    false
  )
)

(define-private (has-role (participant principal) (required-role uint))
  (match (map-get? supply-chain-participants participant)
    participant-info (is-eq (get role participant-info) required-role)
    false
  )
)

(define-private (is-temperature-compliant (batch-id (string-ascii 50)) (temperature int))
  (match (map-get? drug-batches batch-id)
    batch-info 
      (if (get is-cold-chain batch-info)
        (and (>= temperature (get min-temp-required batch-info))
             (<= temperature (get max-temp-required batch-info)))
        (and (>= temperature MIN-TEMP)
             (<= temperature MAX-TEMP)))
    false
  )
)

(define-private (batch-expired (batch-id (string-ascii 50)))
  (match (map-get? drug-batches batch-id)
    batch-info (> block-height (get expiration-date batch-info))
    true
  )
)

(define-private (add-location-to-history (batch-id (string-ascii 50)) (location-id uint))
  (let (
    (current-history (default-to (list) (map-get? batch-location-history batch-id)))
  )
    (map-set batch-location-history
      batch-id
      (unwrap-panic (as-max-len? (append current-history location-id) u20))
    )
  )
)

;; Public Functions
(define-public (register-participant
    (name (string-utf8 100))
    (role uint)
    (location (string-utf8 100))
  )
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (has-role tx-sender ROLE-REGULATOR)) ERR-NOT-AUTHORIZED)
    
    (map-set supply-chain-participants
      tx-sender
      {
        name: name,
        role: role,
        authorized: true,
        location: location,
        registration-date: block-height,
        total-batches-handled: u0
      }
    )
    
    (ok true)
  )
)

(define-public (register-drug-batch
    (batch-id (string-ascii 50))
    (drug-name (string-utf8 100))
    (ndc-code (string-ascii 20))
    (units-produced uint)
    (manufacturing-date uint)
    (expiration-date uint)
    (is-cold-chain bool)
    (min-temp int)
    (max-temp int)
  )
  (let (
    (new-batch-id (+ (var-get batch-counter) u1))
  )
    (asserts! (has-role tx-sender ROLE-MANUFACTURER) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? drug-batches batch-id)) ERR-BATCH-ALREADY-EXISTS)
    (asserts! (> expiration-date manufacturing-date) ERR-EXPIRED-BATCH)
    
    (map-set drug-batches
      batch-id
      {
        manufacturer: tx-sender,
        drug-name: drug-name,
        ndc-code: ndc-code,
        units-produced: units-produced,
        manufacturing-date: manufacturing-date,
        expiration-date: expiration-date,
        status: STATUS-MANUFACTURED,
        is-cold-chain: is-cold-chain,
        min-temp-required: (if is-cold-chain min-temp COLD-CHAIN-MIN),
        max-temp-required: (if is-cold-chain max-temp COLD-CHAIN-MAX),
        created-at: block-height,
        last-updated: block-height,
        is-authentic: true,
        counterfeit-flags: u0
      }
    )
    
    ;; Set regulatory compliance defaults
    (map-set regulatory-compliance
      batch-id
      {
        fda-approved: true,
        dscsa-compliant: true,
        gmp-certified: true,
        last-inspection: block-height,
        compliance-score: u100,
        violations: u0
      }
    )
    
    ;; Update counters
    (var-set batch-counter new-batch-id)
    (var-set total-batches-tracked (+ (var-get total-batches-tracked) u1))
    
    (ok batch-id)
  )
)

(define-public (update-location
    (batch-id (string-ascii 50))
    (location-name (string-utf8 100))
    (temperature int)
    (humidity uint)
    (notes (string-utf8 200))
  )
  (let (
    (location-id (+ (var-get location-counter) u1))
    (batch-info (unwrap! (map-get? drug-batches batch-id) ERR-BATCH-NOT-FOUND))
  )
    (asserts! (is-authorized-participant tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-authentic batch-info) ERR-COUNTERFEIT-FLAGGED)
    (asserts! (not (batch-expired batch-id)) ERR-EXPIRED-BATCH)
    
    ;; Check temperature compliance
    (let (
      (temp-compliant (is-temperature-compliant batch-id temperature))
    )
      (asserts! temp-compliant ERR-TEMPERATURE-VIOLATION)
      
      ;; Record location
      (map-set batch-locations
        { batch-id: batch-id, location-id: location-id }
        {
          handler: tx-sender,
          location-name: location-name,
          timestamp: block-height,
          temperature: temperature,
          humidity: humidity,
          notes: notes,
          verified: false
        }
      )
      
      ;; Add to location history
      (add-location-to-history batch-id location-id)
      
      ;; Update batch status
      (let (
        (new-status (if (has-role tx-sender ROLE-PHARMACY)
          STATUS-DISPENSED
          (if (has-role tx-sender ROLE-DISTRIBUTOR)
            STATUS-DISTRIBUTED
            STATUS-IN-TRANSIT)))
      )
        (map-set drug-batches
          batch-id
          (merge batch-info
            {
              status: new-status,
              last-updated: block-height
            }
          )
        )
      )
      
      ;; Update participant stats
      (let (
        (participant-info (unwrap-panic (map-get? supply-chain-participants tx-sender)))
      )
        (map-set supply-chain-participants
          tx-sender
          (merge participant-info
            {
              total-batches-handled: (+ (get total-batches-handled participant-info) u1)
            }
          )
        )
      )
      
      (var-set location-counter location-id)
      (ok location-id)
    )
  )
)

(define-public (report-temperature
    (batch-id (string-ascii 50))
    (temperature int)
    (humidity uint)
    (location (string-utf8 100))
    (device-id (string-ascii 30))
  )
  (let (
    (reading-id (+ (var-get reading-counter) u1))
    (batch-info (unwrap! (map-get? drug-batches batch-id) ERR-BATCH-NOT-FOUND))
    (temp-compliant (is-temperature-compliant batch-id temperature))
  )
    (asserts! (is-authorized-participant tx-sender) ERR-NOT-AUTHORIZED)
    
    (map-set temperature-readings
      { batch-id: batch-id, reading-id: reading-id }
      {
        temperature: temperature,
        humidity: humidity,
        timestamp: block-height,
        location: location,
        device-id: device-id,
        within-range: temp-compliant
      }
    )
    
    ;; If temperature violation, update compliance
    (if (not temp-compliant)
      (let (
        (compliance-info (unwrap-panic (map-get? regulatory-compliance batch-id)))
      )
        (map-set regulatory-compliance
          batch-id
          (merge compliance-info
            {
              violations: (+ (get violations compliance-info) u1),
              compliance-score: (if (> (get compliance-score compliance-info) u10)
                (- (get compliance-score compliance-info) u10)
                u0)
            }
          )
        )
      )
      true
    )
    
    (var-set reading-counter reading-id)
    (ok reading-id)
  )
)

(define-public (verify-authenticity
    (batch-id (string-ascii 50))
    (location (string-utf8 100))
    (notes (string-utf8 200))
  )
  (let (
    (batch-info (unwrap! (map-get? drug-batches batch-id) ERR-BATCH-NOT-FOUND))
  )
    (asserts! (is-authorized-participant tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (batch-expired batch-id)) ERR-EXPIRED-BATCH)
    
    ;; Check if already verified by this participant
    (asserts! (is-none (map-get? batch-verifications { batch-id: batch-id, verifier: tx-sender })) 
              ERR-ALREADY-VERIFIED)
    
    (map-set batch-verifications
      { batch-id: batch-id, verifier: tx-sender }
      {
        verified-at: block-height,
        location: location,
        verification-status: (get is-authentic batch-info),
        notes: notes
      }
    )
    
    (ok (get is-authentic batch-info))
  )
)

(define-public (flag-counterfeit
    (batch-id (string-ascii 50))
    (location (string-utf8 100))
    (reason (string-utf8 300))
  )
  (let (
    (report-id (+ (var-get report-counter) u1))
    (batch-info (unwrap! (map-get? drug-batches batch-id) ERR-BATCH-NOT-FOUND))
  )
    (asserts! (is-authorized-participant tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Create counterfeit report
    (map-set counterfeit-reports
      report-id
      {
        batch-id: batch-id,
        reporter: tx-sender,
        location: location,
        reason: reason,
        timestamp: block-height,
        investigated: false,
        confirmed: false
      }
    )
    
    ;; Update batch with counterfeit flag
    (map-set drug-batches
      batch-id
      (merge batch-info
        {
          status: STATUS-FLAGGED,
          is-authentic: false,
          counterfeit-flags: (+ (get counterfeit-flags batch-info) u1),
          last-updated: block-height
        }
      )
    )
    
    ;; Update global counters
    (var-set report-counter report-id)
    (var-set counterfeit-alerts (+ (var-get counterfeit-alerts) u1))
    
    (ok report-id)
  )
)

(define-public (initiate-recall
    (batch-id (string-ascii 50))
    (reason (string-utf8 300))
  )
  (let (
    (batch-info (unwrap! (map-get? drug-batches batch-id) ERR-BATCH-NOT-FOUND))
  )
    (asserts! (or (is-eq tx-sender (get manufacturer batch-info))
                  (has-role tx-sender ROLE-REGULATOR)) ERR-NOT-AUTHORIZED)
    
    (map-set drug-batches
      batch-id
      (merge batch-info
        {
          status: STATUS-RECALLED,
          is-authentic: false,
          last-updated: block-height
        }
      )
    )
    
    (ok true)
  )
)

;; Read-only functions
(define-read-only (get-batch-details (batch-id (string-ascii 50)))
  (map-get? drug-batches batch-id)
)

(define-read-only (get-participant-info (participant principal))
  (map-get? supply-chain-participants participant)
)

(define-read-only (get-location-details (batch-id (string-ascii 50)) (location-id uint))
  (map-get? batch-locations { batch-id: batch-id, location-id: location-id })
)

(define-read-only (get-batch-location-history (batch-id (string-ascii 50)))
  (map-get? batch-location-history batch-id)
)

(define-read-only (get-temperature-reading (batch-id (string-ascii 50)) (reading-id uint))
  (map-get? temperature-readings { batch-id: batch-id, reading-id: reading-id })
)

(define-read-only (get-counterfeit-report (report-id uint))
  (map-get? counterfeit-reports report-id)
)

(define-read-only (get-verification-status (batch-id (string-ascii 50)) (verifier principal))
  (map-get? batch-verifications { batch-id: batch-id, verifier: verifier })
)

(define-read-only (get-regulatory-compliance (batch-id (string-ascii 50)))
  (map-get? regulatory-compliance batch-id)
)

(define-read-only (check-authenticity (batch-id (string-ascii 50)))
  (match (map-get? drug-batches batch-id)
    batch-info {
      is-authentic: (get is-authentic batch-info),
      status: (get status batch-info),
      counterfeit-flags: (get counterfeit-flags batch-info),
      expired: (batch-expired batch-id)
    }
    { is-authentic: false, status: u999, counterfeit-flags: u999, expired: true }
  )
)

(define-read-only (get-contract-stats)
  {
    total-batches: (var-get batch-counter),
    total-locations: (var-get location-counter),
    counterfeit-alerts: (var-get counterfeit-alerts),
    temperature-readings: (var-get reading-counter),
    counterfeit-reports: (var-get report-counter)
  }
)
