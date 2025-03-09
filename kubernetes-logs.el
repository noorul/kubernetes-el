;;; kubernetes-logs.el --- Utilities for working with log buffers.  -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:

(require 'subr-x)

(require 'kubernetes-modes)
(require 'kubernetes-pods)
(require 'kubernetes-utils)

(autoload 'json-pretty-print-buffer "json")

(require 'kubernetes-vars)

(defconst kubernetes-logs-supported-resource-types
  '("pod" "deployment" "statefulset" "job")
  "List of Kubernetes resource types that support the `kubectl logs` command.")

(defun kubernetes-logs--read-resource-if-needed (state)
  "Read a resource from the minibuffer if none is at point using STATE.
Returns a cons cell of (type . name)."
  (or (when-let ((resource-info (kubernetes-utils-get-resource-info-at-point)))
        (when (member (car resource-info) kubernetes-logs-supported-resource-types)
          resource-info))
      ;; No loggable resource at point, default to pod selection
      (cons "pod" (kubernetes-pods--read-name state))))

(defun kubernetes-logs--log-line-buffer-for-string (s)
  "Create a buffer to display log line S."
  (let ((propertized (with-temp-buffer
                       (insert s)
                       (goto-char (point-min))
                       (when (equal (char-after) ?\{)
                         (json-pretty-print-buffer)
                         (funcall kubernetes-json-mode)
                         (font-lock-ensure))
                       (buffer-string))))

    (with-current-buffer (get-buffer-create kubernetes-log-line-buffer-name)
      (kubernetes-log-line-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert propertized)
        (goto-char (point-min)))
      (current-buffer))))

;;;###autoload
(defun kubernetes-logs-inspect-line (pos)
  "Show detail for the log line at POS."
  (interactive "d")
  (display-buffer (kubernetes-logs--log-line-buffer-for-string
                   (save-excursion
                     (goto-char pos)
                     (buffer-substring (line-beginning-position) (line-end-position))))))

;;;###autoload
(defun kubernetes-logs-previous-line ()
  "Move backward and inspect the line at point."
  (interactive)
  (with-current-buffer kubernetes-logs-buffer-name
    (forward-line -1)
    (when (get-buffer kubernetes-log-line-buffer-name)
      (kubernetes-logs-inspect-line (point)))))

;;;###autoload
(defun kubernetes-logs-forward-line ()
  "Move forward and inspect the line at point."
  (interactive)
  (with-current-buffer kubernetes-logs-buffer-name
    (forward-line 1)
    (when (get-buffer kubernetes-log-line-buffer-name)
      (kubernetes-logs-inspect-line (point)))))

;;;###autoload
(defun kubernetes-logs-follow (args state)
  "Open a streaming logs buffer for a resource at point or selected by user.
ARGS are additional args to pass to kubectl.
STATE is the current application state."
  (interactive
   (let ((state (kubernetes-state)))
     (list (transient-args 'kubernetes-logs)
           state)))
  (let* ((resource-info (kubernetes-logs--read-resource-if-needed state))
         (resource-type (car resource-info))
         (resource-name (cdr resource-info)))
    (kubernetes-logs-fetch-all resource-type resource-name (cons "-f" args) state)))

;;;###autoload
(defun kubernetes-logs-fetch-all (resource-type resource-name args state)
  "Open a streaming logs buffer for a resource.

RESOURCE-TYPE is the type of resource (pod, deployment, statefulset, job, cronjob).
RESOURCE-NAME is the name of the resource to log.
ARGS are additional args to pass to kubectl.
STATE is the current application state."
  (interactive
   (let* ((state (kubernetes-state))
          (resource-info (kubernetes-logs--read-resource-if-needed state)))
     (list (car resource-info)
           (cdr resource-info)
           (transient-args 'kubernetes-logs)
           state)))

  ;; Format the resource in the kubectl resource/name format
  (let* ((resource-path (if (string= resource-type "pod")
                            resource-name
                          (format "%s/%s" resource-type resource-name)))
         (args (append (list "logs") args (list resource-path) (kubernetes-kubectl--flags-from-state state)
                       (when-let (ns (kubernetes-state--get state 'current-namespace))
                         (list (format "--namespace=%s" ns))))))
    (with-current-buffer (kubernetes-utils-process-buffer-start kubernetes-logs-buffer-name #'kubernetes-logs-mode kubernetes-kubectl-executable args)
      (select-window (display-buffer (current-buffer))))))

(transient-define-prefix kubernetes-logs ()
  "Fetch or tail logs from Kubernetes resources."
  [["Flags"
    ("-a" "Print logs from all containers in this pod" "--all-containers=true")
    ("-p" "Print logs for previous instances of the container in this pod" "-p")
    ("-t" "Include timestamps on each line in the log output" "--timestamps=true")]
   ["Options"
    ("=c" "Select container" "--container=" kubernetes-utils-read-container-name)
    ("=t" "Number of lines to display" "--tail=" transient-read-number-N+)]
   ["Time"
    ("=s" "Since relative time" "--since=" kubernetes-utils-read-time-value)
    ("=d" "Since absolute datetime" "--since-time=" kubernetes-utils-read-iso-datetime)]]
  [["Actions"
    ("l" "Logs" kubernetes-logs-fetch-all)
    ("f" "Logs (stream and follow)" kubernetes-logs-follow)]])

;;;###autoload
(defvar kubernetes-logs-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "n") #'kubernetes-logs-forward-line)
    (define-key keymap (kbd "p") #'kubernetes-logs-previous-line)
    (define-key keymap (kbd "RET") #'kubernetes-logs-inspect-line)
    (define-key keymap (kbd "M-w") nil)
    keymap)
  "Keymap for `kubernetes-logs-mode'.")

;;;###autoload
(define-derived-mode kubernetes-logs-mode kubernetes-mode "Kubernetes Logs"
  "Mode for displaying and inspecting Kubernetes logs.

\\<kubernetes-logs-mode-map>\
Type \\[kubernetes-logs-inspect-line] to open the line at point in a new buffer.

\\{kubernetes-logs-mode-map}")

;;;###autoload
(defvar kubernetes-log-line-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "n") #'kubernetes-logs-forward-line)
    (define-key keymap (kbd "p") #'kubernetes-logs-previous-line)
    keymap)
  "Keymap for `kubernetes-log-line-mode'.")

;;;###autoload
(define-derived-mode kubernetes-log-line-mode kubernetes-mode "Log Line"
  "Mode for inspecting Kubernetes log lines.

\\{kubernetes-log-line-mode-map}")

(provide 'kubernetes-logs)

;;; kubernetes-logs.el ends here
