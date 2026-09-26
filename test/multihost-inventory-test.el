;;; multihost-inventory-test.el --- Inventory contract tests -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Multihost contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'multihost-inventory)

(defmacro multihost-test-with-inventory-json (json &rest body)
  "Write JSON to a temporary FILE while evaluating BODY."
  (declare (indent 1))
  `(let ((file (make-temp-file "multihost-inventory-" nil ".json")))
     (unwind-protect
         (progn (with-temp-file file (insert ,json)) ,@body)
       (delete-file file))))

(defun multihost-test-inventory-fixture ()
  "Return an ordered fixture with overlapping groups."
  (list (make-multihost-host :name "web-2" :connection "web-2" :groups '("prod" "web"))
        (make-multihost-host :name "db-1" :connection "db-1" :groups '("prod" "db"))
        (make-multihost-host :name "web-1" :connection "web-1" :groups '("web" "stage"))))

(ert-deftest multihost-inventory-json-valid ()
  (multihost-test-with-inventory-json
      "{\"version\":1,\"hosts\":[{\"name\":\"web\",\"connection\":\"web-alias\",\"groups\":[\"prod\",\"prod\"],\"description\":\"Frontend\"},{\"name\":\"db\",\"connection\":\"/ssh:jump|ssh:ops@db#2222:/srv\"}]}"
    (let ((hosts (multihost-inventory-load file)))
      (should (equal (mapcar #'multihost-host-name hosts) '("web" "db")))
      (should (equal (multihost-host-groups (car hosts)) '("prod")))
      (should (equal (multihost-host-description (car hosts)) "Frontend"))
      (should (equal (multihost-host-directory (cadr hosts)) "/ssh:jump|ssh:ops@db#2222:/srv/")))))

(ert-deftest multihost-inventory-json-invalid ()
  (dolist (json '("[]" "null" "{}" "{\"version\":2,\"hosts\":[]}"
                  "{\"version\":1,\"hosts\":[]}"
                  "{\"version\":1,\"hosts\":{}}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\"}],\"password\":\"no\"}"
                  "{\"version\":1,\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"name\":\"y\",\"connection\":\"x\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\"},{\"name\":\"x\",\"connection\":\"y\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\",\"password\":\"no\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\",\"groups\":\"prod\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\",\"groups\":[1]}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\",\"description\":null}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"@x\",\"connection\":\"x\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"/tmp\"}]}"
                  "{\"version\":1,\"hosts\":[{\"name\":\"x\",\"connection\":\"x\"}]} trailing"))
    (multihost-test-with-inventory-json json
      (should-error (multihost-inventory-load file) :type 'multihost-inventory-error))))

(ert-deftest multihost-inventory-literal-selectors ()
  (should (equal (mapcar #'multihost-host-name
                         (multihost-select-hosts '("db web" ["db" "backup"])))
                 '("db" "web" "backup")))
  (should (equal (multihost-host-directory (car (multihost-select-hosts "web"))) "/ssh:web:~/"))
  (should (equal (multihost-host-directory (car (multihost-select-hosts "/ssh:ops@[::1]#2222:/srv")))
                 "/ssh:ops@[::1]#2222:/srv/")))

(ert-deftest multihost-inventory-selection-order-and-exclusions ()
  (let ((inventory (multihost-test-inventory-fixture)))
    (should (equal (mapcar #'multihost-host-name (multihost-select-hosts "web-1 @prod *" inventory))
                   '("web-1" "web-2" "db-1")))
    (should (equal (mapcar #'multihost-host-name (multihost-select-hosts "web-*" inventory))
                   '("web-2" "web-1")))
    (should (equal (mapcar #'multihost-host-name (multihost-select-hosts "!db-1 @prod web-1" inventory "web-2"))
                   '("web-1")))
    (should (equal (mapcar #'multihost-host-name (multihost-select-hosts "web db !db")) '("web")))))

(ert-deftest multihost-inventory-case-sensitive-and-local-json ()
  (let ((inventory (list (make-multihost-host :name "WEB-1" :connection "upper")
                         (make-multihost-host :name "web-1" :connection "lower"))))
    (should (equal (mapcar #'multihost-host-name (multihost-select-hosts "web-*" inventory)) '("web-1"))))
  (should-error (multihost-inventory-load "/ssh:must-not-connect:/inventory.json")
                :type 'multihost-inventory-error))

(ert-deftest multihost-inventory-invalid-selectors ()
  (dolist (spec '(nil "" "@prod" "*" "(progn (error \"must never evaluate\"))" 4 thing ("a" . "b") "-oProxyCommand=evil" "alice@web" "web !web"))
    (should-error (multihost-select-hosts spec) :type 'multihost-inventory-error))
  (let ((inventory (multihost-test-inventory-fixture)))
    (dolist (spec '("typo" "@typo" "absent-*" "!web-1" "@prod !@prod" "* !absent"))
      (should-error (multihost-select-hosts spec inventory) :type 'multihost-inventory-error))))

(ert-deftest multihost-inventory-never-evaluates ()
  (let ((called nil))
    (cl-letf (((symbol-function 'eval) (lambda (&rest _) (setq called t))))
      (should-error (multihost-select-hosts "(setq unsafe t)") :type 'multihost-inventory-error))
    (should-not called)))

(ert-deftest multihost-inventory-selection-copies-data ()
  (let* ((source (make-multihost-host :name (copy-sequence "web") :connection (copy-sequence "alias")
                                      :groups (list (copy-sequence "prod")) :description (copy-sequence "Web")))
         (selected (car (multihost-select-hosts "@prod" (list source)))))
    (aset (multihost-host-name source) 0 ?x)
    (aset (multihost-host-connection source) 0 ?x)
    (aset (car (multihost-host-groups source)) 0 ?x)
    (aset (multihost-host-description source) 0 ?x)
    (should (equal (multihost-host-name selected) "web"))
    (should (equal (multihost-host-connection selected) "alias"))
    (should (equal (multihost-host-groups selected) '("prod")))
    (should (equal (multihost-host-description selected) "Web"))))

(ert-deftest multihost-inventory-routing-preserved ()
  (dolist (connection '("/ssh:ops@web#2222:/srv" "/ssh:jump|ssh:ops@web#2222:/srv"
                         "/ssh:jump|sudo:root@web:/srv" "/ssh:jump|ssh:web|sudo:root@web:/srv"))
    (let* ((tramp-default-proxies-alist nil)
           (host (make-multihost-host :name "test" :connection connection))
           (prefix (substring connection 0 (- (length connection) 4))))
      (should (equal (multihost-host-directory host "/var/log") (concat prefix "/var/log/")))
      (should-not tramp-default-proxies-alist)))
  (should (equal (multihost-host-directory (make-multihost-host :name "test" :connection "/ssh:web:"))
                 "/ssh:web:~/")))

(ert-deftest multihost-inventory-rejects-local-or-ambiguous-routing ()
  (dolist (connection '("/tmp" "relative/path" "/sudo:root@localhost:/tmp/" "/su:root@localhost:/tmp/"
                         "/ssh:web:relative" "web\n-oProxyCommand=x" ""
                         "/ssh::/" "/ssh:ops@:/" "/ssh:jump|sudo::/" "/ssh:-Fconfig:/"
                         "/ssh:web#0:/" "/ssh:web#99999:/"))
    (should-error (multihost-host-directory (make-multihost-host :name "bad" :connection connection))
                  :type 'multihost-inventory-error))
  (let ((host (make-multihost-host :name "web" :connection "web")))
    (dolist (dir '("relative" "" "/ssh:other:/tmp/" "/tmp\n"))
      (should-error (multihost-host-directory host dir) :type 'multihost-inventory-error))
    (should (equal (multihost-host-directory host "~/project") "/ssh:web:~/project/"))))

(ert-deftest multihost-inventory-preflight-does-not-connect ()
  (cl-letf (((symbol-function 'process-file) (lambda (&rest _) (ert-fail "process-file during validation")))
            ((symbol-function 'start-file-process) (lambda (&rest _) (ert-fail "process during validation")))
            ((symbol-function 'tramp-maybe-open-connection) (lambda (&rest _) (ert-fail "connection during validation"))))
    (should (equal (multihost-host-directory (car (multihost-select-hosts "/ssh:jump|ssh:ops@web#2222:/srv")) "/tmp")
                   "/ssh:jump|ssh:ops@web#2222:/tmp/"))))

(provide 'multihost-inventory-test)
;;; multihost-inventory-test.el ends here
