create database demo;

GRANT ALL PRIVILEGES ON demo.* TO 'mysqluser'@'%';

USE demo;

create table customers (
	id INT,
	full_name VARCHAR(50),
	birthdate DATE,
	fav_animal VARCHAR(50),
	fav_colour VARCHAR(50),
	fav_movie VARCHAR(50)
);
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (1, 'Leone Puxley', '1995-02-06', 'Violet-eared waxbill', 'Puce', 'Oh! What a Lovely War');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (2, 'Angelo Sharkey', '1996-04-08', 'Macaw, green-winged', 'Red', 'View from the Top, A');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (3, 'Jozef Bailey', '1954-07-10', 'Little brown bat', 'Indigo', '99 francs');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (4, 'Evelyn Deakes', '1975-09-13', 'Vervet monkey', 'Teal', 'Jane Austen in Manhattan');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (5, 'Dermot Perris', '1991-01-29', 'African ground squirrel (unidentified)', 'Khaki', 'Restless');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (6, 'Renae Bonsale', '1965-01-05', 'Brown antechinus', 'Fuscia', 'Perfect Day, A (Un giorno perfetto)');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (7, 'Florella Fridlington', '1950-08-07', 'Burmese brown mountain tortoise', 'Purple', 'Dot the I');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (8, 'Hettie Keepence', '1971-10-14', 'Crab-eating raccoon', 'Puce', 'Outer Space');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (9, 'Briano Quene', '1990-05-02', 'Cormorant, large', 'Yellow', 'Peacekeeper, The');
insert into customers (id, full_name, birthdate, fav_animal, fav_colour, fav_movie) values (10, 'Jeddy Cassell', '1978-12-24', 'Badger, european', 'Indigo', 'Shadow of a Doubt');