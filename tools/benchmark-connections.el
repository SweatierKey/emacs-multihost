;;; benchmark-connections.el --- Reproducible connection measurements -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'json)
(require 'multihost-engine)

(defvar multihost-benchmark--ticks nil)

(defun multihost-benchmark--sample (function)
  "Call FUNCTION and return its value plus timing and parent timer evidence."
  (let* ((multihost-benchmark--ticks nil)
         (start (float-time))
         (timer (run-at-time 0 0.02
                             (lambda () (push (float-time) multihost-benchmark--ticks))))
         value)
    (unwind-protect
        (progn
          (setq value (funcall function))
          (accept-process-output nil 0.03))
      (cancel-timer timer))
    (let* ((end (float-time))
           (ticks (nreverse multihost-benchmark--ticks))
           (points (append (list start) ticks (list end)))
           (gaps (cl-loop for (left right) on points while right collect (- right left))))
      `((elapsed_seconds . ,(- end start))
        (parent_timer_ticks . ,(length ticks))
        (parent_timer_max_gap_seconds . ,(apply #'max gaps))
        (value . ,value)))))

(defun multihost-benchmark--wait (run)
  "Wait for final metadata, rather than only terminal job states, in RUN."
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (multihost-run-ended-at run)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (unless (multihost-run-ended-at run)
      (multihost-cancel run)
      (error "Benchmark deadline exceeded"))))

(defun multihost-benchmark-main ()
  "Measure first and repeated calls on the same generated SSH fixture."
  (let* ((lab (file-name-as-directory (getenv "MULTIHOST_LAB_ROOT")))
         (multihost-state-directory (expand-file-name "benchmark-state" lab))
         (multihost-worker-init-file (expand-file-name "worker-init.el" lab))
         (host (make-multihost-host :name "web" :connection
                                    (concat "/ssh:mh-lab-web:" lab "web/")))
         (directory (multihost-host-directory host))
         (spec '(:language "sh" :body "printf 'SSH=%s\\n' \"$SSH_CONNECTION\"; cat status.txt"
                          :params ((:results . "output") (:session . "none"))))
         (count (string-to-number (or (getenv "MULTIHOST_BENCH_COUNT") "6")))
         scheduled foreground delayed)
    (when (fboundp 'multihost-connection-reset) (multihost-connection-reset))
    (dotimes (index count)
      (push
       (multihost-benchmark--sample
        (lambda ()
          (let* (worker-pid
                 (run (multihost-start
                       spec (list host) :timeout 20 :concurrency 1
                       :callback (lambda (_run job)
                                   (when (and job (process-live-p (multihost-job-process job)))
                                     (setq worker-pid (process-id (multihost-job-process job))))))))
            (multihost-benchmark--wait run)
            (let ((job (car (multihost-run-jobs run))))
              (unless (eq (multihost-job-status job) 'succeeded)
                (error "Scheduled sample failed: %S" (multihost-job-error job)))
              `((iteration . ,index) (worker_pid . ,worker-pid)
                (job_seconds . ,(- (multihost-job-ended-at job) (multihost-job-started-at job)))
                (stdout . ,(multihost-job-stdout job)))))))
       scheduled))
    ;; This comparison describes ordinary synchronous TRAMP reuse.  Timer
    ;; delivery is an observation, not proof that all GUI input is responsive.
    (dotimes (index 2)
      (push (multihost-benchmark--sample
             (lambda ()
               (let ((result (multihost-execute-spec spec directory)))
                 (unless (eq (plist-get result :status) 'succeeded)
                   (error "Direct TRAMP sample failed: %S" result))
                 `((iteration . ,index) (stdout . ,(plist-get result :stdout))))))
            foreground))
    (when-let ((init (getenv "MULTIHOST_BENCH_SLOW_INIT_FILE")))
      (let ((multihost-worker-init-file init))
        (setq delayed
              (multihost-benchmark--sample
               (lambda ()
                 (let ((run (multihost-start spec (list host) :timeout 20)))
                   (multihost-benchmark--wait run)
                   (let ((job (car (multihost-run-jobs run))))
                     (unless (eq (multihost-job-status job) 'succeeded)
                       (error "Delayed initialization failed: %s" (multihost-job-error job)))
                     `((imposed_ssh_delay_seconds . 1.2)
                       (stdout . ,(multihost-job-stdout job))))))))))
    (when (fboundp 'multihost-connection-reset) (multihost-connection-reset))
    (with-temp-file (getenv "MULTIHOST_BENCH_RESULT")
      (insert (json-encode
               `((emacs . ,emacs-version) (tramp . ,tramp-version)
                 (timer_interval_seconds . 0.02)
                 (scheduled . ,(vconcat (nreverse scheduled)))
                 (direct_tramp_reference . ,(vconcat (nreverse foreground)))
                 (delayed_ssh_initialization . ,delayed)))))))

(multihost-benchmark-main)
;;; benchmark-connections.el ends here
