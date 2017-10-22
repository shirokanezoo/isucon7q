alter table message add index chidid (`channel_id`,`id`);
alter table image add index idxname (name);
alter table user modify avatar_icon varchar(100);
alter table user modify display_name varchar(512);
