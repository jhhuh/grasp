(module prelude
  (export map filter fold-left fold-right
          length append reverse
          not and or
          abs min max
          nth range)

  (define not (lambda (x) (if x #f #t)))

  (define and (lambda (a b) (if a b #f)))

  (define or (lambda (a b) (if a #t b)))

  (define abs (lambda (n) (if (< n 0) (- 0 n) n)))

  (define min (lambda (a b) (if (< a b) a b)))

  (define max (lambda (a b) (if (> a b) a b)))

  (define length (lambda (lst)
    (loop ((l lst) (n 0))
      (if (null? l) n
        (recur (cdr l) (+ n 1))))))

  (define reverse (lambda (lst)
    (loop ((l lst) (acc '()))
      (if (null? l) acc
        (recur (cdr l) (cons (car l) acc))))))

  (define append (lambda (a b)
    (loop ((l (reverse a)) (acc b))
      (if (null? l) acc
        (recur (cdr l) (cons (car l) acc))))))

  (define map (lambda (f lst)
    (loop ((l lst) (acc '()))
      (if (null? l) (reverse acc)
        (recur (cdr l) (cons (f (car l)) acc))))))

  (define filter (lambda (pred lst)
    (loop ((l lst) (acc '()))
      (if (null? l) (reverse acc)
        (if (pred (car l))
          (recur (cdr l) (cons (car l) acc))
          (recur (cdr l) acc))))))

  (define fold-left (lambda (f init lst)
    (loop ((acc init) (l lst))
      (if (null? l) acc
        (recur (f acc (car l)) (cdr l))))))

  (define fold-right (lambda (f init lst)
    (fold-left (lambda (acc x) (f x acc)) init (reverse lst))))

  (define nth (lambda (n lst)
    (loop ((i n) (l lst))
      (if (= i 0) (car l)
        (recur (- i 1) (cdr l))))))

  (define range (lambda (start end)
    (loop ((i start) (acc '()))
      (if (= i end) (reverse acc)
        (recur (+ i 1) (cons i acc)))))))
