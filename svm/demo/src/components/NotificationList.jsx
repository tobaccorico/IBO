import React, { useContext } from "react"
import { Notification } from "./Notification"
import { NotificationContext } from "../contexts/NotificationProvider"

import "./Styles/NotificationList.scss"

export const NotificationList = () => {
  const { notifications, close } = useContext(NotificationContext);
  return (
    <div className="notificationList-notificationListRoot">
      {notifications.map(notification => (
        <Notification
          {...notification}
          key={notification.timestamp}
          className="notificationList-notificationListItem"
          onClose={() => close(notification)}
        />
      ))}
    </div>
  );
};
