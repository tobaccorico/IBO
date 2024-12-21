import React from "react";
import cn from "classnames";
import { Icon } from "./Icon";

import styles from "./Styles/Notification.scss"

export const Notification = ({
  className,
  severity = "info",
  message,
  onClose
}) => (
  <div
    tabIndex={0}
    role="button"
    className={cn(styles.notificationRoot, styles[`notification-${severity}`], className)}
    onClick={onClose}
  >
    <p className={styles.notificationMessage}>{message}</p>
    <Icon
      name="btn-bg"
      preserveAspectRatio="none"
      className={styles.notificationBackground}
    />
  </div>
);
